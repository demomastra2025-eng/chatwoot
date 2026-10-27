class Captain::Conversation::TypingIndicatorService
  # The typing indicator is shown as the AI, never as an agent: the channel has no agent of its own.
  def self.turn_on(conversation:)
    new(conversation: conversation).turn_on
  end

  def self.turn_off(conversation:)
    new(conversation: conversation).turn_off
  end

  def initialize(conversation:)
    @conversation = conversation
  end

  def turn_on
    toggle('on')
  end

  def turn_off
    toggle('off')
  end

  private

  def toggle(status)
    return if @conversation.blank?

    ::Conversations::TypingStatusManager.new(
      @conversation,
      Captain::AiActor.instance,
      typing_status: status,
      is_private: true
    ).toggle_typing_status
  end
end
