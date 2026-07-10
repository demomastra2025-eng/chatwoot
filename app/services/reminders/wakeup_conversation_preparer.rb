class Reminders::WakeupConversationPreparer
  attr_reader :conversation

  def initialize(conversation:)
    @conversation = conversation
  end

  def perform
    return if conversation.pending?

    if conversation.respond_to?(:with_captain_activity_context)
      conversation.with_captain_activity_context(reason: 'touch_ai_wakeup', reason_type: :touch) do
        transition_to_pending!
      end
    else
      transition_to_pending!
    end
  end

  private

  def transition_to_pending!
    Conversations::StatusTransitionService.new(
      conversation: conversation,
      params: { status: 'pending' },
      source: 'system'
    ).perform
  end
end
