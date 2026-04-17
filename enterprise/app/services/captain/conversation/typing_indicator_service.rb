class Captain::Conversation::TypingIndicatorService
  def self.turn_on(conversation:, assistant:)
    new(conversation: conversation, assistant: assistant).turn_on
  end

  def self.turn_off(conversation:, assistant:)
    new(conversation: conversation, assistant: assistant).turn_off
  end

  def initialize(conversation:, assistant:)
    @conversation = conversation
    @assistant = assistant || resolve_assistant
  end

  def turn_on
    toggle('on')
  end

  def turn_off
    toggle('off')
  end

  private

  def toggle(status)
    return if @conversation.blank? || @assistant.blank?

    ::Conversations::TypingStatusManager.new(
      @conversation,
      @assistant,
      typing_status: status,
      is_private: true
    ).toggle_typing_status
  end

  def resolve_assistant
    return if @conversation.blank?

    ::CaptainInbox.find_by(inbox_id: @conversation.inbox_id)&.captain_assistant
  end
end
