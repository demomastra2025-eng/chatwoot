class Campaigns::CaptainGeneratedMessageService
  REQUEST = <<~TEXT.freeze
    Generate exactly one outbound message for this campaign recipient.
    Return only the final message content to send to the customer.
    Do not include explanations, metadata, labels, markdown fences, or internal reasoning.
  TEXT

  attr_reader :campaign, :conversation

  def initialize(campaign:, conversation:)
    @campaign = campaign
    @conversation = conversation
  end

  def perform
    raise ArgumentError, 'Captain runtime is not available' unless defined?(Captain::Assistant::AgentRunnerService)

    assistant = generation_assistant(resolve_base_assistant!)
    response = with_executor(assistant) do
      Captain::Assistant::AgentRunnerService.new(
        assistant: assistant,
        conversation: conversation,
        source: 'campaign_agent'
      ).generate_response(message_history: generation_message_history(assistant))
    end.with_indifferent_access

    content = response[:response].to_s.strip
    raise ArgumentError, 'Captain requested a handoff instead of a message' if content == 'conversation_handoff'
    raise ArgumentError, 'Captain generated blank campaign content' if content.blank?

    {
      assistant: assistant,
      content: content,
      captain_trace: response[:captain_trace]
    }.compact
  end

  private

  def resolve_base_assistant!
    assistant = conversation.inbox&.captain_assistant
    raise ArgumentError, 'Captain assistant is not configured for this campaign' if assistant.blank?

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
    [
      base_assistant.system_instruction.presence,
      "Campaign instructions:\n#{campaign.instructions}",
      REQUEST
    ].compact.join("\n\n")
  end

  def generation_message_history(assistant)
    collect_previous_messages(assistant) + [
      {
        role: 'user',
        content: 'Generate the outbound campaign message now, using the campaign instructions and current conversation context.'
      }
    ]
  end

  def collect_previous_messages(assistant)
    messages = if assistant.history_message_limit_value.positive?
                 conversation.messages
                             .where(message_type: [:incoming, :outgoing])
                             .where(private: false)
                             .reorder(created_at: :desc)
                             .limit(assistant.history_message_limit_value)
                             .to_a
                             .reverse
               else
                 conversation.messages
                             .where(message_type: [:incoming, :outgoing])
                             .where(private: false)
                             .to_a
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

  def with_executor(assistant)
    previous_executor = Current.executed_by
    Current.executed_by = assistant
    yield
  ensure
    Current.executed_by = previous_executor
  end
end
