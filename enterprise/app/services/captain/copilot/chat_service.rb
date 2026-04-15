require 'securerandom'

class Captain::Copilot::ChatService < Llm::BaseAiService
  include Captain::ChatHelper

  attr_reader :assistant, :account, :user, :copilot_thread, :previous_history, :messages

  def initialize(assistant, config)
    super()

    @assistant = assistant
    @account = assistant.account
    @user = nil
    @copilot_thread = nil
    @previous_history = []
    @conversation = @account.conversations.find_by(display_id: config[:conversation_id])
    @conversation_id = @conversation&.display_id

    setup_user(config)
    setup_message_history(config)
    @tools = build_tools
    @messages = build_messages
  end

  def generate_response(input)
    Llm::EventBus.with_context(request_event_context) do
      input_moderation_response = moderate_input_response(input)
      return input_moderation_response if input_moderation_response

      @messages << { role: 'user', content: input } if input.present?
      response = request_chat_completion

      Rails.logger.debug { "#{self.class.name} Assistant: #{@assistant.id}, Received response #{response}" }
      Rails.logger.info(
        "#{self.class.name} Assistant: #{@assistant.id}, Incrementing response usage for account #{@account.id}"
      )
      @account.increment_response_usage
      @account.increment_token_usage(response.dig('usage', 'total_tokens'))

      response
    end
  end

  private

  def setup_user(config)
    @user = @account.users.find_by(id: config[:user_id]) if config[:user_id].present?
  end

  def build_messages
    messages = [system_message, account_context_message]
    messages += @previous_history if @previous_history.present?
    conversation_context = conversation_context_message
    messages << conversation_context if conversation_context.present?
    messages
  end

  def setup_message_history(config)
    Rails.logger.info(
      "#{self.class.name} Assistant: #{@assistant.id}, Previous History: #{config[:previous_history]&.length || 0}, Language: #{config[:language]}"
    )

    @copilot_thread = @account.copilot_threads.find_by(id: config[:copilot_thread_id]) if config[:copilot_thread_id].present?
    @previous_history = if @copilot_thread.present?
                          @copilot_thread.previous_history
                        else
                          config[:previous_history].presence || []
                        end
  end

  def build_tools
    @assistant.allowed_assistant_tools.filter_map do |tool_definition|
      next unless Captain::ToolPolicy.runtime_allowed?(
        tool_definition,
        assistant: @assistant,
        scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
        user: @user
      )

      Captain::Copilot::ToolCatalog.build_tool(
        tool_definition,
        assistant: @assistant,
        user: @user,
        conversation: @conversation
      )
    end.select(&:active?)
  end

  def system_message
    {
      role: 'system',
      content: Captain::Llm::SystemPromptsService.copilot_response_generator(
        @assistant.name,
        @assistant.system_instruction,
        tools_summary,
        @assistant.config
      )
    }
  end

  def tools_summary
    Captain::ToolCatalog.summary_for(
      @tools.map { |tool| { id: tool.name, description: tool.description } }
    )
  end

  def account_context_message
    {
      role: 'system',
      content: Captain::Llm::SystemPromptsService.copilot_account_context(@account)
    }
  end

  def conversation_context_message
    return if @conversation.blank?

    Rails.logger.info(
      "#{self.class.name} Assistant: #{@assistant.id}, Setting viewing history for conversation_id=#{@conversation.display_id}"
    )

    {
      role: 'system',
      content: Captain::Llm::SystemPromptsService.copilot_conversation_context(@conversation)
    }
  end

  def persist_message(message, message_type = 'assistant')
    return if @copilot_thread.blank?

    @copilot_thread.copilot_messages.create!(
      message: message,
      message_type: message_type
    )
  end

  def feature_name
    'copilot'
  end

  def response_schema
    Captain::Llm::Schemas::CopilotResponse
  end

  def llm_feature_key
    feature_name
  end

  def llm_model_account
    @account
  end

  def moderate_input_response(input)
    Llm::SafetyPolicy.check!(
      feature: :copilot,
      stage: :input,
      content: input,
      account: @account
    )
    nil
  rescue Llm::SafetyPolicy::UnsafeContentError
    blocked_response_payload('Copilot input blocked by moderation policy')
  rescue Llm::SafetyPolicy::UnavailableError
    blocked_response_payload('Copilot input blocked because moderation policy is unavailable')
  end

  def moderate_response_payload(parsed_response)
    Llm::SafetyPolicy.check!(
      feature: :copilot,
      stage: :output,
      content: parsed_response['content'],
      account: @account
    )
    parsed_response
  rescue Llm::SafetyPolicy::UnsafeContentError
    blocked_response_payload('Copilot output blocked by moderation policy')
  rescue Llm::SafetyPolicy::UnavailableError
    blocked_response_payload('Copilot output blocked because moderation policy is unavailable')
  end

  def blocked_response_payload(reason)
    {
      'content' => "I can't help with that request.",
      'reasoning' => reason,
      'reply_suggestion' => false
    }
  end

  def request_event_context
    {
      request_id: SecureRandom.uuid,
      feature: feature_name,
      runtime_mode: 'captain_chat',
      account_id: resolved_account_id,
      assistant_id: @assistant&.id,
      conversation_id: @conversation&.id,
      conversation_display_id: @conversation&.display_id || @conversation_id,
      copilot_thread_id: @copilot_thread&.id,
      channel_type: resolved_channel_type,
      source: @source,
      session_id: copilot_session_id
    }.compact
  end

  def copilot_session_id
    return "#{resolved_account_id}_#{@conversation.display_id}" if @conversation&.display_id.present?
    return "#{resolved_account_id}_copilot_thread_#{@copilot_thread.id}" if @copilot_thread&.id.present?

    nil
  end

  def structured_output_fallback_payload(_error)
    {
      'content' => "I couldn't generate a reliable copilot response. Please try again.",
      'reasoning' => 'Copilot structured output validation failed',
      'reply_suggestion' => false
    }
  end
end
