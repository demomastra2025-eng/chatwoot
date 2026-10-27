# frozen_string_literal: true

# The conversation history the agent of a reply suggestion receives, in the OpenAI message format.
#
# Every image of the history is described (parallel and cached, see ImageDescriber), so the agent knows what each image shows. The
# agent receives that text only, never the pixels or a link to the image (see Captain::OpenAiMessageBuilderService). The budget
# (Captain::Conversation::HistoryBudget) limits the text of the documents.
class Captain::ReplySuggestion::HistoryBuilder
  FALLBACK_USER_PROMPT = 'Suggest the next reply for the customer based on the conversation and context.'

  pattr_initialize [:account!, :conversation!, :assistant!]

  def perform
    messages = history_messages
    descriptions = describe_images(messages)
    budget = Captain::Conversation::HistoryBudget.new
    # Newest first: the budget of the documents is spent on the latest messages. Then back to the order of the conversation.
    history = messages.reverse.map { |message| history_entry(message, budget, descriptions) }.reverse
    history << { role: 'user', content: FALLBACK_USER_PROMPT } if history.none? { |entry| entry[:role] == 'user' }
    history
  end

  private

  def history_messages
    limit = assistant.history_message_limit_value
    scope = Captain::Conversation::ControlService
            .messages_scope(conversation)
            .where(message_type: [:incoming, :outgoing])
            .where(private: false)
    return scope.reorder(created_at: :asc, id: :asc).to_a unless limit.positive?

    scope.reorder(created_at: :desc, id: :desc).limit(limit).to_a.reverse
  end

  def describe_images(messages)
    targets = messages.flat_map { |message| message_builder(message).describable_images }
    return {} if targets.empty?

    Captain::ReplySuggestion::ImageDescriber.new(account: account, targets: targets).perform
  end

  def message_builder(message, budget: nil, descriptions: nil)
    Captain::OpenAiMessageBuilderService.new(message: message, assistant: assistant, budget: budget, image_descriptions: descriptions)
  end

  # sent_at: the runner writes each message after its send time and gives the time of the message being answered to the prompt
  # clock (see Captain::Assistant::RunPayloadHelper#stamped_content): a suggestion often answers a message of an earlier day.
  def history_entry(message, budget, descriptions)
    entry = {
      content: message_builder(message, budget: budget, descriptions: descriptions).generate_content,
      role: message.message_type == 'incoming' ? 'user' : 'assistant',
      sent_at: message.created_at
    }
    agent_name = message.additional_attributes.to_h['agent_name'].presence
    entry[:agent_name] = agent_name if agent_name.present?
    entry
  end
end
