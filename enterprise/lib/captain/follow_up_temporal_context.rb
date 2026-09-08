# frozen_string_literal: true

class Captain::FollowUpTemporalContext
  pattr_initialize [:conversation!, :assistant!, { now: nil }]

  def as_json
    local_now = current_time.in_time_zone(timezone)
    {
      language: language,
      timezone: timezone.name,
      local_time: local_now.iso8601,
      day_period: day_period(local_now),
      relative_day: relative_day(local_now)
    }
  end

  private

  def current_time
    now || Time.current
  end

  def language
    @language ||= Captain::FollowUpLanguageResolver.new(conversation: conversation, assistant: assistant).call
  end

  def timezone
    @timezone ||= Time.find_zone!(
      Captain::FollowUpQuietHoursPolicy.new(assistant: assistant, conversation: conversation).call.timezone
    )
  end

  def day_period(local_now)
    return 'morning' if local_now.hour < 12
    return 'day' if local_now.hour < 18

    'evening'
  end

  def relative_day(local_now)
    last_incoming_at = conversation.messages.incoming.reorder(created_at: :desc).pick(:created_at)
    return 'unknown' if last_incoming_at.blank?

    days = (local_now.to_date - last_incoming_at.in_time_zone(timezone).to_date).to_i
    return 'today' if days <= 0
    return 'yesterday' if days == 1
    return 'recently' if days <= 6

    'earlier'
  end
end
