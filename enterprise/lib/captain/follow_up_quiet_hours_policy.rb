# frozen_string_literal: true

class Captain::FollowUpQuietHoursPolicy
  DEFAULT_START_TIME = '23:00'
  DEFAULT_END_TIME = '08:00'
  TIME_PATTERN = /\A(?:[01]\d|2[0-3]):[0-5]\d\z/

  Result = Struct.new(:quiet, :next_allowed_at, :timezone, :reason, keyword_init: true) do
    def quiet?
      quiet
    end
  end

  pattr_initialize [:assistant!, :conversation!, { now: nil }]

  def call
    return allowed_result unless enabled?
    return allowed_result if start_minute == end_minute

    local_now = current_time.in_time_zone(timezone)
    return allowed_result unless quiet_at?(local_now)

    Result.new(
      quiet: true,
      next_allowed_at: next_allowed_local_time(local_now).utc,
      timezone: timezone.name,
      reason: 'quiet_hours'
    )
  end

  private

  def current_time
    now || Time.current
  end

  def settings
    @settings ||= assistant.config.to_h.deep_stringify_keys
                         .fetch('follow_up_settings', {}).to_h
                         .fetch('quiet_hours', {}).to_h
  end

  def enabled?
    ActiveModel::Type::Boolean.new.cast(settings['enabled'])
  end

  def timezone
    @timezone ||= timezone_candidates.filter_map { |value| Time.find_zone(value) }.first ||
                  Time.find_zone!('UTC')
  end

  def inbox_timezone
    inbox = conversation.inbox
    return assistant.account.workspace_working_hours_timezone if inbox&.inherit_working_hours_from_account?

    inbox&.timezone
  end

  def timezone_candidates
    [
      settings['timezone'].presence,
      inbox_timezone.presence,
      assistant.account.try(:workspace_timezone).presence,
      assistant.account.reporting_timezone.presence,
      Time.zone.name
    ].compact
  end

  def start_minute
    @start_minute ||= minute_of_day(settings['start_time'], DEFAULT_START_TIME)
  end

  def end_minute
    @end_minute ||= minute_of_day(settings['end_time'], DEFAULT_END_TIME)
  end

  def minute_of_day(value, fallback)
    normalized = value.to_s.match?(TIME_PATTERN) ? value.to_s : fallback
    hour, minute = normalized.split(':').map(&:to_i)
    (hour * 60) + minute
  end

  def quiet_at?(local_time)
    current_minute = (local_time.hour * 60) + local_time.min
    if start_minute < end_minute
      current_minute >= start_minute && current_minute < end_minute
    else
      current_minute >= start_minute || current_minute < end_minute
    end
  end

  def next_allowed_local_time(local_now)
    target_date = local_now.to_date
    target_date += 1.day if start_minute > end_minute && ((local_now.hour * 60) + local_now.min) >= start_minute
    timezone.local(target_date.year, target_date.month, target_date.day, end_minute / 60, end_minute % 60)
  end

  def allowed_result
    Result.new(quiet: false, timezone: timezone.name)
  end
end
