class Reminders::CaptainGeneratedMessageService
  TOUCH_REQUEST = <<~TEXT.freeze
    Generate exactly one outbound message for the scheduled touch.
    Return only the final message content to send to the customer.
    Do not include explanations, metadata, labels, markdown fences, or internal reasoning.
  TEXT

  WAKEUP_REQUEST = <<~TEXT.freeze
    Review the conversation and send the best next proactive follow-up message now.
    Return only the final message content to send to the customer.
    Do not include explanations, metadata, labels, markdown fences, or internal reasoning.
  TEXT

  attr_reader :reminder, :conversation, :mode

  def initialize(reminder:, conversation:, mode: :touch)
    @reminder = reminder
    @conversation = conversation
    @mode = mode.to_sym
  end

  def perform
    raise ArgumentError, 'Captain runtime is not available' unless captain_runtime_available?

    assistant = generation_assistant(resolve_base_assistant!)
    response = with_executor(assistant) do
      Captain::Assistant::AgentRunnerService.new(
        assistant: assistant,
        conversation: conversation,
        source: source_name
      ).generate_response(message_history: generation_message_history(assistant))
    end.with_indifferent_access

    content = response[:response].to_s.strip
    raise ArgumentError, 'Captain requested a handoff instead of a message' if content == 'conversation_handoff'
    raise ArgumentError, 'Captain generated blank touch content' if content.blank?

    {
      assistant: assistant,
      content: content,
      captain_trace: response[:captain_trace]
    }.compact
  end

  private

  def captain_runtime_available?
    defined?(Captain::Assistant::AgentRunnerService)
  end

  def touch_mode?
    mode == :touch
  end

  def wakeup_mode?
    mode == :wakeup
  end

  def source_name
    wakeup_mode? ? 'touch_ai_wakeup' : 'touch_agent'
  end

  def resolve_base_assistant!
    assistant_id = reminder.metadata['captain_assistant_id'].presence

    assistant =
      if assistant_id.present?
        conversation.account.captain_assistants.find_by(id: assistant_id)
      else
        conversation.inbox&.captain_assistant
      end

    raise ArgumentError, 'Captain assistant is not configured for this touch' if assistant.blank?

    assistant
  end

  def generation_assistant(base_assistant)
    assistant = base_assistant.dup
    assistant.account = base_assistant.account
    assistant.config = (base_assistant.config || {}).deep_dup
    assistant.response_guidelines = Array(base_assistant.response_guidelines).deep_dup
    assistant.guardrails = Array(base_assistant.guardrails).deep_dup
    assistant.description = combined_instruction(base_assistant)
    assistant
  end

  def combined_instruction(base_assistant)
    parts = [base_assistant.system_instruction.presence]
    parts << "Scheduled touch instructions:\n#{reminder.instructions}" if touch_mode?
    parts << (wakeup_mode? ? WAKEUP_REQUEST : TOUCH_REQUEST)
    parts.compact.join("\n\n")
  end

  def generation_message_history(assistant)
    collect_previous_messages(assistant) + [{ role: 'user', content: generation_prompt }]
  end

  def generation_prompt
    if wakeup_mode?
      'Generate the next proactive follow-up message for this conversation now.'
    else
      'Generate the scheduled touch message now, following the touch instructions and current runtime context.'
    end
  end

  def collect_previous_messages(assistant)
    messages = if assistant.history_message_limit_value.positive?
                 conversation_messages_scope.reorder(created_at: :desc)
                                            .limit(assistant.history_message_limit_value)
                                            .to_a
                                            .reverse
               else
                 conversation_messages_scope.to_a
               end

    messages.map do |message|
      payload = {
        content: Captain::OpenAiMessageBuilderService.new(message: message).generate_content,
        role: message.message_type == 'incoming' ? 'user' : 'assistant'
      }
      payload[:agent_name] = message.additional_attributes['agent_name'] if message.additional_attributes&.dig('agent_name').present?
      payload
    end
  end

  def conversation_messages_scope
    conversation.messages
                .where(message_type: [:incoming, :outgoing])
                .where(private: false)
  end

  def with_executor(assistant)
    previous_executor = Current.executed_by
    Current.executed_by = assistant
    yield
  ensure
    Current.executed_by = previous_executor
  end
end
