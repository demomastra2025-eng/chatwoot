# frozen_string_literal: true

# The conversation history the agent of a reply suggestion receives, in the OpenAI message format.
#
# Every image of the history is described (parallel and cached, see ImageDescriber), so the agent knows what each image shows.
# The pixels themselves go to the model for the newest images only, within the same budget as a live run
# (Captain::Conversation::HistoryBudget).
class Captain::ReplySuggestion::HistoryBuilder
  FALLBACK_USER_PROMPT = 'Suggest the next reply for the customer based on the conversation and context.'
  # A voice note with no transcript: the agent reads that it exists and that its words are not known (suggestion eval 27.10: the
  # operator's voice notes had no transcript, the agent saw "Message without content", started the booking again and asked for
  # data the patient had given, when the patient only thanked). A transcript, when there is one, is the text of the message.
  PATIENT_VOICE_NOTE = '[Voice message of the patient; its words are not available to you]'
  STAFF_VOICE_NOTE = '[Voice note of the clinic staff; its words are not available to you]'

  pattr_initialize [:account!, :conversation!, :assistant!]

  def perform
    messages = history_messages
    descriptions = describe_images(messages)
    budget = Captain::Conversation::HistoryBudget.new
    # Newest first: the budget of images is spent on the latest messages. Then back to the order of the conversation.
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
      content: entry_content(message, budget, descriptions),
      role: message.message_type == 'incoming' ? 'user' : 'assistant',
      sent_at: message.created_at
    }
    agent_name = message.additional_attributes.to_h['agent_name'].presence
    entry[:agent_name] = agent_name if agent_name.present?
    entry
  end

  def entry_content(message, budget, descriptions)
    content = message_builder(message, budget: budget, descriptions: descriptions).generate_content
    return content unless content == Captain::OpenAiMessageBuilderService::EMPTY_CONTENT
    return content unless message.attachments.any? { |item| item.file_type == 'audio' }

    message.message_type == 'incoming' ? PATIENT_VOICE_NOTE : STAFF_VOICE_NOTE
  end
end
