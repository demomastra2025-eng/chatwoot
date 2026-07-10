class Reminders::RecurrenceService
  attr_reader :reminder

  def initialize(reminder:)
    @reminder = reminder
  end

  def schedule_next!
    return unless reminder.recurring?

    next_scheduled_at = next_occurrence_at
    return if next_scheduled_at.blank?
    return if reminder.repeat_until_at.present? && next_scheduled_at > reminder.repeat_until_at

    next_touch = reminder.account.reminders.create!(next_touch_attributes(next_scheduled_at))
    next_touch.approve! if next_touch.draft? && next_touch.ready_for_pending?
    next_touch
  end

  private

  def next_occurrence_at
    return if reminder.scheduled_at.blank?

    local_scheduled_at = reminder.scheduled_at.in_time_zone(reminder.timezone.presence || 'UTC')
    case reminder.repeat_mode
    when 'daily'
      local_scheduled_at.advance(days: 1)
    when 'weekly'
      local_scheduled_at.advance(weeks: 1)
    when 'monthly'
      local_scheduled_at.advance(months: 1)
    when 'weekdays'
      next_weekday_occurrence(local_scheduled_at)
    end
  end

  def next_weekday_occurrence(time)
    candidate = time.advance(days: 1)
    candidate = candidate.advance(days: 1) while candidate.saturday? || candidate.sunday?
    candidate
  end

  # rubocop:disable Metrics/MethodLength
  def next_touch_attributes(next_scheduled_at)
    {
      creator: reminder.creator,
      owner: reminder.owner,
      conversation: reminder.conversation,
      remindable: reminder.remindable,
      reminder_group: reminder.reminder_group,
      action_type: reminder.action_type,
      content_kind: reminder.content_kind,
      text_mode: reminder.text_mode,
      timing_mode: reminder.timing_mode,
      repeat_mode: reminder.repeat_mode,
      repeat_until_at: reminder.repeat_until_at,
      scheduled_at: next_scheduled_at,
      timezone: reminder.timezone,
      body: reminder.body,
      instructions: reminder.instructions,
      attachments: reminder.attachments,
      template_params: reminder.template_params,
      metadata: reminder.metadata.except(*Reminder::INTERNAL_METADATA_KEYS),
      auto_cancel_on_incoming: reminder.auto_cancel_on_incoming,
      target_inbox: reminder.target_inbox,
      target_contact: reminder.target_contact,
      target_contact_inbox: reminder.target_contact_inbox,
      target_conversation: reminder.target_conversation
    }.compact
  end
  # rubocop:enable Metrics/MethodLength
end
