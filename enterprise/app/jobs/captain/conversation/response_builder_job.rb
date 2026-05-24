# rubocop:disable Metrics/ClassLength
class Captain::Conversation::ResponseBuilderJob < ApplicationJob
  include FileTypeHelper

  MAX_MESSAGE_LENGTH = 10_000
  MAX_RESPONSE_ARTIFACT_ATTACHMENTS = 10
  SINGLE_ATTACHMENT_MESSAGE_CHANNELS = %w[Channel::Whatsapp Channel::WhatsappWeb].freeze
  AUDIO_TRANSCRIPTION_WAIT_TIMEOUT = 5.seconds
  AUDIO_TRANSCRIPTION_WAIT_INTERVAL = 0.25.seconds
  PROVIDER_ERROR_HANDOFF_RESPONSE = Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE
  ARTIFACT_UNAVAILABLE_RESPONSE = 'The requested file is no longer available. Please ask me to fetch it again.'.freeze
  DOCUMENT_DELIVERY_REQUEST_PATTERN = Regexp.new(
    '((отправ|пришл|вышл|скин|прикреп).{0,80}(документ|файл|pdf|пдф))|' \
    '((документ|файл|pdf|пдф).{0,80}(отправ|пришл|вышл|скин|прикреп))|' \
    '((send|share|attach).{0,80}(document|file|pdf))|' \
    '((document|file|pdf).{0,80}(send|share|attach))',
    Regexp::IGNORECASE
  )
  RECEIPT_ATTACHMENT_CONTEXT = 'The user sent an image after being asked to share a payment receipt/proof. ' \
                               'Treat the image as the requested receipt/payment confirmation unless it clearly shows otherwise; ' \
                               'acknowledge the receipt and continue the active booking/confirmation flow.'.freeze
  RECEIPT_REQUEST_ACTION = '(пришл|отправ|загруз|прикреп|скин|send|share|upload|attach)'.freeze
  RECEIPT_CONTEXT_TERMS = [
    'чек',
    'квитанц',
    'receipt',
    'payment\s+proof',
    'proof\s+of\s+payment',
    'подтвержден\w*\s+оплат\w*',
    'оплат\w*.{0,30}(скрин|фото|proof)',
    'скрин.{0,30}оплат\w*',
    'фото.{0,30}оплат\w*'
  ].freeze
  RECEIPT_CONTEXT_TERM = RECEIPT_CONTEXT_TERMS.join('|').freeze
  RECEIPT_REQUEST_PATTERN = Regexp.new(
    "((#{RECEIPT_REQUEST_ACTION}).{0,80}(#{RECEIPT_CONTEXT_TERM}))|" \
    "((#{RECEIPT_CONTEXT_TERM}).{0,80}(#{RECEIPT_REQUEST_ACTION}))",
    Regexp::IGNORECASE
  )
  queue_as :captain_runtime
  retry_on ActiveStorage::FileNotFoundError, attempts: 3, wait: 2.seconds
  retry_on Faraday::BadRequestError, attempts: 3, wait: 2.seconds

  def perform(conversation, assistant, buffer_token: nil, expected_last_message_id: nil)
    @conversation = conversation
    @inbox = conversation.inbox
    @assistant = assistant
    @buffer_token = buffer_token
    @expected_last_message_id = expected_last_message_id

    return unless current_buffer_state_valid? && conversation_pending?

    Current.executed_by = @assistant

    return process_cancelled_response if response_cancelled?

    maintain_typing_indicator
    generate_and_process_response
  rescue ActiveStorage::FileNotFoundError, Faraday::BadRequestError => e
    cancelled = response_cancelled?
    handle_error(e)
    raise e unless cancelled
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
    return process_cancelled_response if response_cancelled?

    normalize_blank_public_response!

    processed_response =
      if handoff_requested?
        process_action(handoff_action_name)
        account.increment_token_usage(@response.dig('usage', 'total_tokens'))
        true
      elsif conversation_pending?
        process_pending_response
      else
        false
      end

    clear_buffer_state_if_current if processed_response
  end

  def process_pending_response
    attachment_ids = response_attachment_ids
    return process_cancelled_response if response_cancelled?

    ensure_response_content_for_artifact_failure!(attachment_ids)

    ActiveRecord::Base.transaction do
      create_messages(attachment_ids: attachment_ids)
      Rails.logger.info("[CAPTAIN][ResponseBuilderJob] Incrementing response usage for #{account.id}")
      account.increment_response_usage
      account.increment_token_usage(@response.dig('usage', 'total_tokens'))
    end
    true
  end

  def collect_previous_messages
    messages = if history_message_limit.positive?
                 conversation_messages_scope.reorder(created_at: :desc).limit(history_message_limit).to_a.reverse
               else
                 conversation_messages_scope.to_a
               end

    messages.each_with_index.map do |message, index|
      previous_assistant_message = previous_assistant_message_for(messages, index)
      message_hash = {
        content: prepare_multimodal_message_content(message, previous_assistant_message: previous_assistant_message),
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

  def prepare_multimodal_message_content(message, previous_assistant_message: nil)
    content = Captain::OpenAiMessageBuilderService.new(message: message).generate_content
    return content unless receipt_image_after_request?(message, previous_assistant_message)

    append_receipt_attachment_context(content)
  end

  def previous_assistant_message_for(messages, index)
    messages.first(index).reverse.find { |message| message.message_type == 'outgoing' }
  end

  def receipt_image_after_request?(message, previous_assistant_message)
    return false unless message.message_type == 'incoming'
    return false unless previous_assistant_message&.content.to_s.match?(RECEIPT_REQUEST_PATTERN)

    message.attachments.exists?(file_type: :image)
  end

  def append_receipt_attachment_context(content)
    context_part = { type: 'text', text: RECEIPT_ATTACHMENT_CONTEXT }
    return [context_part, *content] if content.is_a?(Array)

    [context_part, { type: 'text', text: content.to_s }]
  end

  def wait_for_audio_transcriptions
    return unless account.captain_audio_transcription_enabled?
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
    v2_handoff_tool_fired? || ['conversation_handoff', PROVIDER_ERROR_HANDOFF_RESPONSE].include?(@response['response'])
  end

  def response_cancelled?
    assistant_cancelled_response? || manager_cancelled_response?
  end

  def assistant_cancelled_response?
    return false if @response.blank?

    ActiveModel::Type::Boolean.new.cast(@response['response_cancelled']) || @response['response'] == 'response_cancelled'
  end

  def manager_cancelled_response?
    return false unless @conversation.present? && @assistant.present?

    response_cancellation_service.cancelled?(
      buffer_token: @buffer_token,
      expected_last_message_id: @expected_last_message_id
    )
  end

  def process_cancelled_response
    account.increment_token_usage(@response.dig('usage', 'total_tokens')) if @response&.dig('usage', 'total_tokens').present?
    clear_buffer_state_if_current
    response_cancellation_service.clear_if_current!(
      buffer_token: @buffer_token,
      expected_last_message_id: @expected_last_message_id
    )
    true
  end

  def response_cancellation_service
    @response_cancellation_service ||= Captain::Conversation::ResponseCancellationService.new(
      conversation: @conversation,
      assistant: @assistant
    )
  end

  def handoff_action_name
    return 'v2_handoff' if v2_handoff_tool_fired?

    provider_error_handoff_requested? ? 'provider_error_handoff' : 'handoff'
  end

  def provider_error_handoff_requested?
    @response['response'] == PROVIDER_ERROR_HANDOFF_RESPONSE
  end

  def normalize_blank_public_response!
    return unless blank_public_response?

    @response = @response.merge(
      'response' => PROVIDER_ERROR_HANDOFF_RESPONSE,
      'reasoning' => 'Provider error occurred: Assistant runtime returned a blank response',
      'error_class' => Captain::Assistant::AgentRunnerService::BlankResponseError.name,
      'error_message' => 'Assistant runtime returned a blank response'
    )
  end

  def blank_public_response?
    return false if @response.blank?
    return false if handoff_requested?
    return false if response_artifact_ids.present?

    @response['response'].blank?
  end

  def v2_handoff_tool_fired?
    @response&.[]('handoff_tool_called')
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
    when 'v2_handoff'
      if conversation_pending?
        I18n.with_locale(@assistant.account.locale) do
          create_handoff_private_note
          create_handoff_message
          @conversation.bot_handoff!
          send_out_of_office_message_if_applicable
        end
      else
        create_handoff_message(preserve_waiting_since: true)
      end
    end
  end

  def send_out_of_office_message_if_applicable
    # Campaign conversations should never receive OOO templates — the campaign itself
    # serves as the initial outreach, and OOO would be confusing in that context.
    return if @conversation.campaign.present?

    ::MessageTemplates::Template::OutOfOffice.perform_if_applicable(@conversation)
  end

  def create_handoff_message(preserve_waiting_since: false)
    return unless @assistant.handoff_message_enabled?

    handoff_message = handoff_message_content
    return if handoff_message.blank?

    I18n.with_locale(@assistant.account.locale) do
      create_outgoing_message(
        @assistant.render_runtime_text(handoff_message, conversation: @conversation),
        preserve_waiting_since: preserve_waiting_since
      )
    end
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

  def create_messages(attachment_ids: [])
    validate_message_content!(@response['response'], attachment_ids: attachment_ids)
    return create_split_attachment_messages(attachment_ids) if split_response_attachments?(attachment_ids)

    create_outgoing_message(
      @response['response'],
      agent_name: @response['agent_name'],
      attachment_ids: attachment_ids
    )
  end

  def create_split_attachment_messages(attachment_ids)
    first_attachment_id, *remaining_attachment_ids = Array(attachment_ids)
    first_message = create_outgoing_message(
      @response['response'],
      agent_name: @response['agent_name'],
      attachment_ids: [first_attachment_id]
    )

    remaining_attachment_ids.each do |attachment_id|
      create_outgoing_message(
        nil,
        agent_name: @response['agent_name'],
        attachment_ids: [attachment_id],
        include_trace: false
      )
    end

    first_message
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

  def validate_message_content!(content, attachment_ids: [])
    raise ArgumentError, 'Message content cannot be blank' if content.blank? && attachment_ids.blank?
  end

  def create_outgoing_message(message_content, agent_name: nil, preserve_waiting_since: false, attachment_ids: [], include_trace: true)
    message = @conversation.messages.build(
      message_type: :outgoing,
      account_id: account.id,
      inbox_id: inbox.id,
      sender: @assistant,
      content: message_content,
      additional_attributes: additional_message_attributes(agent_name: agent_name, include_trace: include_trace),
      preserve_waiting_since: preserve_waiting_since
    )

    Array(attachment_ids).each do |attachment_id|
      build_message_attachment(message, attachment_id)
    end

    message.save!
    message
  end

  def additional_message_attributes(agent_name:, include_trace:)
    {}.tap do |attributes|
      add_agent_name_attributes(attributes, agent_name)
      attributes[:captain_trace] = @response['captain_trace'] if include_trace && @response&.dig('captain_trace').present?
    end
  end

  def add_agent_name_attributes(attributes, agent_name)
    return if agent_name.blank?

    attributes[:agent_name] = agent_name
    display_agent_name = display_agent_name_for(agent_name)
    attributes[:agentName] = display_agent_name if display_agent_name.present?
  end

  def split_response_attachments?(attachment_ids)
    Array(attachment_ids).many? && SINGLE_ATTACHMENT_MESSAGE_CHANNELS.include?(inbox.channel_type)
  end

  def build_message_attachment(message, attachment_id)
    attachment = message.attachments.build(
      account_id: message.account_id,
      file: attachment_id
    )
    attachment.file_type = file_type_by_signed_id(attachment_id)
  end

  def response_attachment_ids
    artifact_ids = response_artifact_ids
    return [] if artifact_ids.blank?

    attachment_resolver.resolve(artifact_ids: artifact_ids)
  rescue Captain::Tools::DocumentArtifactToken::InvalidToken,
         Captain::Tools::HttpArtifactToken::InvalidToken,
         Captain::Tools::HttpArtifactMaterializer::DownloadError,
         AccountLimits::StorageUsageService::LimitExceeded,
         ArgumentError => e
    remember_artifact_resolution_error(e)
    []
  end

  def ensure_response_content_for_artifact_failure!(attachment_ids)
    return if attachment_ids.present?
    return if @artifact_resolution_error.blank?
    return if @response['response'].present?

    @response['response'] = ARTIFACT_UNAVAILABLE_RESPONSE
  end

  def remember_artifact_resolution_error(error)
    @artifact_resolution_error ||= error
    Rails.logger.warn(
      "[CAPTAIN][ARTIFACT] Skipping unavailable response artifact: #{error.class} #{error.message} " \
      "conversation_id=#{@conversation.id} assistant_id=#{@assistant.id} account_id=#{account.id}"
    )
  end

  def response_artifact_ids
    ids = explicit_response_artifact_ids
    ids = inferred_document_artifact_ids if ids.blank?

    ids.filter_map { |artifact_id| artifact_id.to_s.strip.presence }.uniq.first(MAX_RESPONSE_ARTIFACT_ATTACHMENTS)
  end

  def explicit_response_artifact_ids
    raw_artifact_ids = @response&.dig('artifact_ids')
    case raw_artifact_ids
    when Array
      raw_artifact_ids
    when String
      parse_artifact_ids_string(raw_artifact_ids)
    else
      []
    end
  end

  def inferred_document_artifact_ids
    return [] unless document_delivery_requested?

    artifact_ids = listed_sendable_document_artifact_ids
    return [] unless artifact_ids.one?

    Rails.logger.info(
      '[CAPTAIN][DOCUMENT_ARTIFACT] Auto-attaching the only listed sendable document ' \
      "conversation_id=#{@conversation.id} assistant_id=#{@assistant.id} account_id=#{account.id}"
    )
    artifact_ids
  end

  def parse_artifact_ids_string(raw_artifact_ids)
    artifact_ids = raw_artifact_ids.to_s.strip
    return [] if artifact_ids.blank?

    parsed_artifact_ids = JSON.parse(artifact_ids)
    return parsed_artifact_ids if parsed_artifact_ids.is_a?(Array)

    [artifact_ids]
  rescue JSON::ParserError
    artifact_ids.split(/[,\s]+/)
  end

  def document_delivery_requested?
    latest_incoming_message_content.to_s.match?(DOCUMENT_DELIVERY_REQUEST_PATTERN) ||
      @response&.dig('response').to_s.match?(DOCUMENT_DELIVERY_REQUEST_PATTERN)
  end

  def latest_incoming_message_content
    @conversation.messages.incoming.order(created_at: :desc, id: :desc).pick(:content)
  end

  def listed_sendable_document_artifact_ids
    tool_steps = @response&.dig('captain_trace', 'tool_steps') || @response&.dig('captain_trace', :tool_steps)
    Array(tool_steps).flat_map { |step| document_artifact_ids_from_tool_step(step) }.uniq
  end

  def document_artifact_ids_from_tool_step(step)
    return [] unless step.respond_to?(:[])
    return [] unless (step['event'] || step[:event]).to_s == 'finish'
    return [] unless (step['tool_name'] || step[:tool_name]).to_s == 'list_captain_documents'

    payload = document_tool_payload(step['output'] || step[:output])
    return [] unless payload.respond_to?(:[])

    Array(payload['documents'] || payload[:documents]).filter_map do |document|
      next unless document.respond_to?(:[])

      sendable = ActiveModel::Type::Boolean.new.cast(document['sendable'] || document[:sendable])
      artifact_id = document['artifact_id'] || document[:artifact_id]
      artifact_id.to_s if sendable && artifact_id.to_s.start_with?(Captain::Tools::DocumentArtifactToken::PREFIX)
    end
  end

  def document_tool_payload(output)
    normalized_output = output.respond_to?(:to_h) ? output.to_h : {}
    message = normalized_output['message'] || normalized_output[:message]
    data = normalized_output['data'] || normalized_output[:data]
    data_hash = data.respond_to?(:to_h) ? data.to_h : nil
    return data_hash if data_hash.present? && (data_hash['documents'] || data_hash[:documents]).present?

    parsed_message = JSON.parse(message.to_s)
    parsed_message.respond_to?(:to_h) ? parsed_message.to_h : {}
  rescue JSON::ParserError
    {}
  end

  def attachment_resolver
    @attachment_resolver ||= Captain::Tools::AttachmentResolver.new(account: account, assistant: @assistant)
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

  def display_agent_name_for(agent_name)
    @assistant.scenarios.find { |scenario| scenario.handoff_key == agent_name }&.title
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
    return process_cancelled_response if response_cancelled?

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
      on_tool_start: lambda { |tool_name, args = nil, *_rest|
        tool_trace_sequence = append_tool_start_trace(tool_trace_steps, tool_trace_sequence, tool_name, args)
      },
      on_tool_progress: lambda { |tool_name, details = nil, *_rest|
        tool_trace_sequence = append_tool_progress_trace(tool_trace_steps, tool_trace_sequence, tool_name, details)
      },
      on_tool_complete: lambda { |tool_name, result = nil, *_rest|
        tool_trace_sequence = append_tool_completion_trace(tool_trace_steps, tool_trace_sequence, tool_name, result)
      }
    }

    [callbacks, tool_trace_steps]
  end

  def append_tool_start_trace(tool_trace_steps, sequence, tool_name, args)
    maintain_typing_indicator
    sequence += 1
    append_runtime_tool_trace_step(
      tool_trace_steps,
      tool_name: tool_name,
      event: 'start',
      sequence: sequence,
      input: args
    )
    sequence
  end

  def append_tool_progress_trace(tool_trace_steps, sequence, tool_name, details)
    maintain_typing_indicator
    sequence += 1
    append_runtime_tool_trace_step(
      tool_trace_steps,
      tool_name: tool_name,
      event: 'progress',
      sequence: sequence,
      output: details
    )
    sequence
  end

  def append_tool_completion_trace(tool_trace_steps, sequence, tool_name, result)
    maintain_typing_indicator
    normalized_result = Captain::ToolResult.normalize(result)
    sequence += 1
    append_runtime_tool_trace_step(
      tool_trace_steps,
      tool_name: tool_name,
      event: Captain::ToolResult.error?(normalized_result) ? 'failed' : 'finish',
      sequence: sequence,
      output: normalized_result
    )
    sequence
  end

  def append_runtime_tool_trace_step(tool_trace_steps, **)
    tool_trace_steps << Captain::ToolTraceBuilder.step(**)
  end

  def maintain_typing_indicator
    return unless @conversation.present? && @assistant.present?
    return clear_typing_indicator if response_cancelled?

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
    return bufferless_state_valid?(current_last_incoming_message_id) if @buffer_token.blank?

    buffered_state_valid?(current_last_incoming_message_id)
  end

  def bufferless_state_valid?(current_last_incoming_message_id)
    return true if @expected_last_message_id.blank?

    current_last_incoming_message_id.to_i == @expected_last_message_id.to_i
  end

  def buffered_state_valid?(current_last_incoming_message_id)
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
    (conversation_pending? || v2_handoff_tool_fired?) && @conversation.inbox.captain_assistant&.id == @assistant.id
  end
end
# rubocop:enable Metrics/ClassLength
