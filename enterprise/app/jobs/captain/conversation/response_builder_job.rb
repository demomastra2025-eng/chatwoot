class Captain::Conversation::ResponseBuilderJob < ApplicationJob
  MAX_MESSAGE_LENGTH = 10_000
  AUDIO_TRANSCRIPTION_WAIT_TIMEOUT = 5.seconds
  AUDIO_TRANSCRIPTION_WAIT_INTERVAL = 0.25.seconds
  PROVIDER_ERROR_HANDOFF_RESPONSE = Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE
  queue_as :captain_runtime
  retry_on ActiveStorage::FileNotFoundError, attempts: 3, wait: 2.seconds
  retry_on Faraday::BadRequestError, attempts: 3, wait: 2.seconds

  def perform(conversation, assistant, buffer_token: nil, expected_last_message_id: nil)
    @conversation = conversation
    @inbox = conversation.inbox
    @assistant = assistant
    @buffer_token = buffer_token
    @expected_last_message_id = expected_last_message_id

    return unless current_buffer_state_valid?

    return unless conversation_pending?

    Current.executed_by = @assistant

    maintain_typing_indicator
    generate_and_process_response
  rescue ActiveStorage::FileNotFoundError, Faraday::BadRequestError => e
    handle_error(e)
    raise e
  rescue StandardError => e
    handle_error(e)
  ensure
    clear_typing_indicator
    Current.executed_by = nil
  end

  private

  delegate :account, :inbox, to: :@conversation

  def generate_and_process_response
    wait_for_audio_transcriptions

    callbacks, tool_trace_steps = build_tool_trace_callbacks
    @response = Captain::Assistant::AgentRunnerService.new(
      assistant: @assistant,
      conversation: @conversation,
      callbacks: callbacks
    ).generate_response(
      message_history: collect_previous_messages
    )
    attach_tool_trace_to_response!(tool_trace_steps)
    process_response
  end

  def process_response
    return unless current_buffer_state_valid?
    return unless conversation_pending?

    if handoff_requested?
      process_action(handoff_action_name)
      account.increment_token_usage(@response.dig('usage', 'total_tokens'))
    else
      ActiveRecord::Base.transaction do
        create_messages
        Rails.logger.info("[CAPTAIN][ResponseBuilderJob] Incrementing response usage for #{account.id}")
        account.increment_response_usage
        account.increment_token_usage(@response.dig('usage', 'total_tokens'))
      end
    end

    clear_buffer_state_if_current
  end

  def collect_previous_messages
    messages = if history_message_limit.positive?
                 conversation_messages_scope.reorder(created_at: :desc).limit(history_message_limit).to_a.reverse
               else
                 conversation_messages_scope.to_a
               end

    messages.map do |message|
      message_hash = {
        content: prepare_multimodal_message_content(message),
        role: determine_role(message)
      }

      agent_name = message_agent_name_for_history(message)
      message_hash[:agent_name] = agent_name if agent_name.present?

      message_hash
    end
  end

  def conversation_messages_scope
    @conversation
      .messages
      .where(message_type: [:incoming, :outgoing])
      .where(private: false)
  end

  def history_message_limit
    @assistant.history_message_limit_value
  end

  def determine_role(message)
    message.message_type == 'incoming' ? 'user' : 'assistant'
  end

  def prepare_multimodal_message_content(message)
    Captain::OpenAiMessageBuilderService.new(message: message).generate_content
  end

  def wait_for_audio_transcriptions
    return unless account.audio_transcriptions
    return unless pending_audio_transcription?

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AUDIO_TRANSCRIPTION_WAIT_TIMEOUT.to_f

    while pending_audio_transcription?
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep AUDIO_TRANSCRIPTION_WAIT_INTERVAL.to_f
    end
  end

  def pending_audio_transcription?
    incoming_messages_pending_response.any? do |message|
      message.attachments.any? do |attachment|
        attachment.file_type == 'audio' && attachment.meta.to_h['transcribed_text'].blank?
      end
    end
  end

  def incoming_messages_pending_response
    messages = conversation_messages_scope.includes(:attachments).to_a
    latest_outgoing_at = messages.select { |message| message.message_type == 'outgoing' }.filter_map(&:created_at).max

    messages.select do |message|
      message.message_type == 'incoming' && (latest_outgoing_at.blank? || message.created_at > latest_outgoing_at)
    end
  end

  def handoff_requested?
    ['conversation_handoff', PROVIDER_ERROR_HANDOFF_RESPONSE].include?(@response['response'])
  end

  def handoff_action_name
    provider_error_handoff_requested? ? 'provider_error_handoff' : 'handoff'
  end

  def provider_error_handoff_requested?
    @response['response'] == PROVIDER_ERROR_HANDOFF_RESPONSE
  end

  def process_action(action)
    case action
    when 'handoff'
      I18n.with_locale(@assistant.account.locale) do
        create_handoff_private_note
        create_handoff_message
        @conversation.bot_handoff!
        send_out_of_office_message_if_applicable
      end
    when 'provider_error_handoff'
      create_provider_error_private_note
      @conversation.bot_handoff!
      send_out_of_office_message_if_applicable
    end
  end

  def send_out_of_office_message_if_applicable
    # Campaign conversations should never receive OOO templates — the campaign itself
    # serves as the initial outreach, and OOO would be confusing in that context.
    return if @conversation.campaign.present?

    ::MessageTemplates::Template::OutOfOffice.perform_if_applicable(@conversation)
  end

  def create_handoff_message
    return unless @assistant.handoff_message_enabled?

    handoff_message = handoff_message_content
    return if handoff_message.blank?

    create_outgoing_message(
      @assistant.render_runtime_text(handoff_message, conversation: @conversation)
    )
  end

  def handoff_message_content
    return @response['handoff_message'].presence if @assistant.handoff_message_mode_value == Captain::Assistant::MESSAGE_MODE_AI

    @assistant.config['handoff_message'].presence
  end

  def create_handoff_private_note
    reason = @response['handoff_reason'].to_s.strip
    return if reason.blank?

    create_private_note(reason)
  end

  def create_messages
    validate_message_content!(@response['response'])
    create_outgoing_message(
      @response['response'],
      agent_name: @response['agent_name']
    )
  end

  def create_provider_error_private_note
    create_private_note(provider_error_note_content)
  end

  def provider_error_note_content(error = nil)
    error_class = error&.class&.name || @response['error_class']
    error_message = error&.message || @response['error_message'] || @response['reasoning']
    normalized_message = error_message.to_s.squish.first(MAX_MESSAGE_LENGTH)
    note = "AI runtime fallback: #{error_class.presence || 'UnknownError'}"
    note += ": #{normalized_message}" if normalized_message.present?
    note
  end

  def validate_message_content!(content)
    raise ArgumentError, 'Message content cannot be blank' if content.blank?
  end

  def create_outgoing_message(message_content, agent_name: nil)
    additional_attrs = {}
    additional_attrs[:agent_name] = agent_name if agent_name.present?
    additional_attrs[:captain_trace] = @response['captain_trace'] if @response&.dig('captain_trace').present?

    @conversation.messages.create!(
      message_type: :outgoing,
      account_id: account.id,
      inbox_id: inbox.id,
      sender: @assistant,
      content: message_content,
      additional_attributes: additional_attrs
    )
  end

  def create_private_note(message_content)
    @conversation.messages.create!(
      message_type: :outgoing,
      private: true,
      account_id: account.id,
      inbox_id: inbox.id,
      sender: @assistant,
      content: message_content,
      additional_attributes: private_note_additional_attributes
    )
  end

  def private_note_additional_attributes
    additional_attrs = {}
    additional_attrs[:captain_trace] = @response['captain_trace'] if @response&.dig('captain_trace').present?
    additional_attrs
  end

  def message_agent_name_for_history(message)
    explicit_agent_name = message.additional_attributes&.dig('agent_name').presence
    return explicit_agent_name if explicit_agent_name.present?
    return unless message.sender_type == 'Captain::Assistant'

    inferred_agent_name_from_trace(message.additional_attributes&.dig('captain_trace'))
  end

  def inferred_agent_name_from_trace(trace_payload)
    tool_steps = trace_payload&.dig('tool_steps') || trace_payload&.dig(:tool_steps)
    return if tool_steps.blank?

    last_handoff_tool_name = Array(tool_steps).reverse.filter_map do |step|
      next unless (step['event'] || step[:event]).to_s == 'complete'

      tool_name = (step['tool_name'] || step[:tool_name]).to_s
      next unless tool_name.start_with?('handoff_to_')

      tool_name
    end.first

    last_handoff_tool_name&.delete_prefix('handoff_to_')&.presence
  end

  def handle_error(error)
    log_error(error)
    return true unless current_buffer_state_valid?

    if conversation_pending?
      @response ||= {}
      @response['error_class'] = error.class.name
      @response['error_message'] = error.message
      process_action('provider_error_handoff')
    end
    clear_buffer_state_if_current
    true
  end

  def log_error(error)
    ChatwootExceptionTracker.new(error, account: account).capture_exception
  end

  def build_tool_trace_callbacks
    tool_trace_steps = []
    tool_trace_sequence = 0

    callbacks = {
      on_agent_thinking: lambda { |_agent_name, *_args|
        maintain_typing_indicator
      },
      on_tool_start: lambda { |tool_name, *_args|
        maintain_typing_indicator
        tool_trace_sequence += 1
        tool_trace_steps << Captain::ToolTraceBuilder.step(
          tool_name: tool_name,
          event: 'start',
          sequence: tool_trace_sequence
        )
      },
      on_tool_complete: lambda { |tool_name, *_args|
        maintain_typing_indicator
        tool_trace_sequence += 1
        tool_trace_steps << Captain::ToolTraceBuilder.step(
          tool_name: tool_name,
          event: 'complete',
          sequence: tool_trace_sequence
        )
      }
    }

    [callbacks, tool_trace_steps]
  end

  def maintain_typing_indicator
    Captain::Conversation::TypingIndicatorService.turn_on(
      conversation: @conversation,
      assistant: @assistant
    )
    @typing_indicator_active = true
  end

  def clear_typing_indicator
    return unless @typing_indicator_active

    Captain::Conversation::TypingIndicatorService.turn_off(
      conversation: @conversation,
      assistant: @assistant
    )
    @typing_indicator_active = false
  end

  def attach_tool_trace_to_response!(tool_trace_steps = nil)
    return if @response.blank?
    return if @response['captain_trace'].present?

    payload = Captain::ToolTraceBuilder.payload(tool_trace_steps)
    @response['captain_trace'] = payload if payload.present?
  end

  def conversation_pending?
    status = Conversation.uncached { Conversation.where(id: @conversation.id).pick(:status) }
    status == 'pending' || status == Conversation.statuses[:pending]
  end

  def current_buffer_state_valid?
    return false unless conversation_eligible_for_response?

    current_last_incoming_message_id = @conversation.reload.messages.incoming.last&.id

    if @buffer_token.blank?
      return true if @expected_last_message_id.blank?

      return current_last_incoming_message_id.to_i == @expected_last_message_id.to_i
    end

    state = current_buffer_state
    return false if state.blank?

    state['token'] == @buffer_token &&
      state['last_message_id'].to_i == @expected_last_message_id.to_i &&
      current_last_incoming_message_id.to_i == @expected_last_message_id.to_i
  end

  def clear_buffer_state_if_current
    return if @buffer_token.blank?

    state = current_buffer_state
    return unless state.present? && state['token'] == @buffer_token

    Redis::Alfred.delete(buffer_state_key)
  end

  def current_buffer_state
    raw_state = Redis::Alfred.get(buffer_state_key)
    return if raw_state.blank?

    JSON.parse(raw_state)
  rescue JSON::ParserError
    nil
  end

  def buffer_state_key
    format(::Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_STATE, conversation_id: @conversation.id)
  end

  def conversation_eligible_for_response?
    conversation_pending? && @conversation.inbox.captain_assistant&.id == @assistant.id
  end
end
