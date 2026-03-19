class Captain::Conversation::ResponseBuilderJob < ApplicationJob
  MAX_MESSAGE_LENGTH = 10_000
  retry_on ActiveStorage::FileNotFoundError, attempts: 3, wait: 2.seconds
  retry_on Faraday::BadRequestError, attempts: 3, wait: 2.seconds

  def perform(conversation, assistant, buffer_token: nil, expected_last_message_id: nil)
    @conversation = conversation
    @inbox = conversation.inbox
    @assistant = assistant
    @buffer_token = buffer_token
    @expected_last_message_id = expected_last_message_id

    return unless current_buffer_state_valid?

    Current.executed_by = @assistant

    if captain_v2_enabled?
      generate_response_with_v2
    else
      generate_and_process_response
    end
  rescue StandardError => e
    raise e if e.is_a?(ActiveStorage::FileNotFoundError) || e.is_a?(Faraday::BadRequestError)

    handle_error(e)
  ensure
    Current.executed_by = nil
  end

  private

  delegate :account, :inbox, to: :@conversation

  def generate_and_process_response
    @response = Captain::Llm::AssistantChatService.new(assistant: @assistant, conversation_id: @conversation.display_id).generate_response(
      message_history: collect_previous_messages
    )
    process_response
  end

  def generate_response_with_v2
    @response = Captain::Assistant::AgentRunnerService.new(assistant: @assistant, conversation: @conversation).generate_response(
      message_history: collect_previous_messages
    )
    process_response
  end

  def process_response
    return unless current_buffer_state_valid?

    ActiveRecord::Base.transaction do
      if handoff_requested?
        process_action('handoff')
      else
        create_messages
        Rails.logger.info("[CAPTAIN][ResponseBuilderJob] Incrementing response usage for #{account.id}")
        account.increment_response_usage
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

      # Include agent_name if present in additional_attributes
      message_hash[:agent_name] = message.additional_attributes['agent_name'] if message.additional_attributes&.dig('agent_name').present?

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

  def handoff_requested?
    @response['response'] == 'conversation_handoff'
  end

  def process_action(action)
    case action
    when 'handoff'
      I18n.with_locale(@assistant.account.locale) do
        create_handoff_message
        @conversation.bot_handoff!
        send_out_of_office_message_if_applicable
      end
    end
  end

  def send_out_of_office_message_if_applicable
    # Campaign conversations should never receive OOO templates — the campaign itself
    # serves as the initial outreach, and OOO would be confusing in that context.
    return if @conversation.campaign.present?

    ::MessageTemplates::Template::OutOfOffice.perform_if_applicable(@conversation)
  end

  def create_handoff_message
    create_outgoing_message(
      @assistant.config['handoff_message'].presence || I18n.t('conversations.captain.handoff')
    )
  end

  def create_messages
    validate_message_content!(@response['response'])
    create_outgoing_message(@response['response'], agent_name: @response['agent_name'])
  end

  def validate_message_content!(content)
    raise ArgumentError, 'Message content cannot be blank' if content.blank?
  end

  def create_outgoing_message(message_content, agent_name: nil)
    additional_attrs = {}
    additional_attrs[:agent_name] = agent_name if agent_name.present?

    @conversation.messages.create!(
      message_type: :outgoing,
      account_id: account.id,
      inbox_id: inbox.id,
      sender: @assistant,
      content: message_content,
      additional_attributes: additional_attrs
    )
  end

  def handle_error(error)
    log_error(error)
    return true unless current_buffer_state_valid?

    process_action('handoff')
    clear_buffer_state_if_current
    true
  end

  def log_error(error)
    ChatwootExceptionTracker.new(error, account: account).capture_exception
  end

  def captain_v2_enabled?
    account.feature_enabled?('captain_integration_v2')
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
    @conversation.pending? && @conversation.inbox.captain_assistant&.id == @assistant.id
  end
end
