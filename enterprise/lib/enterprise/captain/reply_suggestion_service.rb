module Enterprise::Captain::ReplySuggestionService
  FALLBACK_USER_PROMPT = 'Suggest the next reply for the customer based on the conversation and context.'.freeze
  NON_DELIVERABLE_RESPONSES = [
    'conversation_handoff',
    'response_cancelled',
    Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE
  ].freeze
  DEFAULT_USAGE = { 'prompt_tokens' => 0, 'completion_tokens' => 0, 'total_tokens' => 0 }.freeze

  def perform_reply_suggestion
    assistant = entry_assistant_for_suggestion
    return super if assistant.blank?

    perform_agent_reply_suggestion(assistant) || super
  end

  def make_api_call(model:, messages:, tools: [])
    return super unless use_search_tool?

    super(model: model, messages: messages, tools: [build_search_tool])
  end

  private

  def entry_assistant_for_suggestion
    return if conversation.blank? || conversation.inbox&.channel_type == 'Channel::Voice'

    inbox_assistant = conversation.inbox&.captain_assistant
    return inbox_assistant if inbox_assistant&.entry_eligible?

    default_account_assistant
  end

  def default_account_assistant
    default_id = account.captain_default_assistant_id
    default_assistant = account.captain_assistants.entry_eligible.find_by(id: default_id) if default_id.present?
    default_assistant || account.captain_assistants.entry_eligible.order(:id).first
  end

  def perform_agent_reply_suggestion(assistant)
    return { error: I18n.t('captain.api_key_missing'), error_code: 401 } unless api_key_configured?

    raw_response = Captain::Assistant::AgentRunnerService.new(
      assistant: assistant,
      conversation: conversation,
      source: 'reply_suggestion'
    ).generate_response(message_history: suggestion_message_history(assistant))

    build_agent_suggestion_result(raw_response)
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ReplySuggestionService] Agent suggestion fallback: #{e.class}: #{e.message}")
    nil
  end

  def build_agent_suggestion_result(raw_response)
    payload = raw_response.to_h.with_indifferent_access
    content = payload[:response].to_s.strip
    return if non_deliverable_agent_payload?(payload, content)

    result = { message: content, usage: payload[:usage].presence || DEFAULT_USAGE }
    return result unless build_follow_up_context?

    result.merge(follow_up_context: build_follow_up_context([{ role: 'user', content: formatted_conversation }], result))
  end

  def non_deliverable_agent_payload?(payload, content)
    content.blank? ||
      NON_DELIVERABLE_RESPONSES.include?(content) ||
      payload[:error_class].present? ||
      payload.values_at(:moderation_blocked, :response_suppressed, :response_cancelled).include?(true)
  end

  def suggestion_message_history(assistant)
    history = suggestion_messages(assistant).map { |message| build_suggestion_history_entry(message, assistant) }
    history << { role: 'user', content: FALLBACK_USER_PROMPT } if history.none? { |entry| entry[:role] == 'user' }
    history
  end

  def suggestion_messages(assistant)
    limit = assistant.history_message_limit_value
    scope = Captain::Conversation::ControlService
            .messages_scope(conversation)
            .where(message_type: [:incoming, :outgoing])
            .where(private: false)
    return scope.reorder(created_at: :asc, id: :asc).to_a unless limit.positive?

    scope.reorder(created_at: :desc, id: :desc).limit(limit).to_a.reverse
  end

  def build_suggestion_history_entry(message, assistant)
    entry = {
      content: Captain::OpenAiMessageBuilderService.new(message: message, assistant: assistant).generate_content,
      role: message.message_type == 'incoming' ? 'user' : 'assistant'
    }
    agent_name = message.additional_attributes.to_h['agent_name'].presence
    entry[:agent_name] = agent_name if agent_name.present?
    entry
  end

  def use_search_tool?
    ChatwootApp.chatwoot_cloud? || ChatwootApp.self_hosted_enterprise?
  end

  def prompt_variables
    return super unless use_search_tool?

    super.merge('has_search_tool' => true)
  end

  def build_search_tool
    assistant = conversation&.inbox&.captain_assistant
    Captain::Tools::SearchReplyDocumentationService.new(account: account, assistant: assistant)
  end
end
