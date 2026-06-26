class Reminders::SyncConversationTimingService
  attr_reader :conversation, :exclude_touch_id

  def initialize(conversation:, exclude_touch_id: nil)
    @conversation = conversation
    @exclude_touch_id = exclude_touch_id.presence
  end

  def perform
    relevant_touches.find_each do |touch|
      sync_touch!(touch)
    rescue StandardError => e
      ChatwootExceptionTracker.new(e, account: conversation.account).capture_exception
    end
  end

  private

  def relevant_touches
    scope = conversation.account.reminders
                        .where(status: [Reminder.statuses[:draft], Reminder.statuses[:pending]])
                        .where(timing_mode: Reminder.timing_modes[:relative])
                        .where(manual_schedule_override: false)
                        .where(relative_anchor: Reminder::CONVERSATION_DYNAMIC_RELATIVE_ANCHORS)
                        .where(
                          [
                            'conversation_id = :conversation_id',
                            'target_conversation_id = :conversation_id',
                            '(remindable_type = :remindable_type AND remindable_id = :conversation_id)'
                          ].join(' OR '),
                          conversation_id: conversation.id,
                          remindable_type: 'Conversation'
                        )

    return scope if exclude_touch_id.blank?

    scope.where.not(id: exclude_touch_id)
  end

  def sync_touch!(touch)
    touch.scheduled_at_will_change!
    touch.save!
    touch.approve! if touch.reload.draft? && touch.ready_for_pending?
  end
end
