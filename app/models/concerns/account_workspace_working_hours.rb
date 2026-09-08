module AccountWorkspaceWorkingHours
  extend ActiveSupport::Concern

  DEFAULT_TIMEZONE = 'Asia/Almaty'.freeze
  DEFAULT_SCHEDULE = (0..6).map do |day|
    if day.zero? || day == 6
      { 'day_of_week' => day, 'closed_all_day' => true, 'open_all_day' => false }
    else
      {
        'day_of_week' => day,
        'closed_all_day' => false,
        'open_hour' => 9,
        'open_minutes' => 0,
        'close_hour' => 17,
        'close_minutes' => 0,
        'open_all_day' => false
      }
    end
  end.freeze

  included do
    store_accessor :settings, :workspace_working_hours_enabled, :workspace_timezone, :workspace_working_hours,
                   :workspace_breaks, :workspace_days_off
    validate :validate_workspace_timezone
    validate :validate_workspace_working_hours
    validate :validate_workspace_breaks
  end

  def workspace_working_hours_enabled?
    true
  end

  def workspace_working_hours_timezone
    workspace_timezone.presence || DEFAULT_TIMEZONE
  end

  def workspace_working_hours_schedule
    schedule = workspace_working_hours
    return DEFAULT_SCHEDULE.deep_dup unless schedule.is_a?(Array) && schedule.size == 7

    schedule.map(&:deep_stringify_keys)
  end

  def workspace_working_hours_configured?
    true
  end

  def workspace_break_schedule
    Array(workspace_breaks).filter_map do |entry|
      break_entry = entry.to_h.deep_stringify_keys
      days = Array(break_entry['days']).filter_map { |day| Integer(day, exception: false) }.select { |day| day.between?(0, 6) }.uniq
      next if days.empty? || minute_for_time(break_entry['start_time']).nil? || minute_for_time(break_entry['end_time']).nil?

      break_entry.merge('days' => days)
    end
  end

  def workspace_days_off_schedule
    Array(workspace_days_off).filter_map do |entry|
      day_off = entry.to_h.deep_stringify_keys
      next unless Date.iso8601(day_off['date'].to_s)

      day_off
    rescue Date::Error
      nil
    end
  end

  def workspace_open_at?(time = Time.current)
    local_time = time.in_time_zone(workspace_working_hours_timezone)
    return false if workspace_day_off?(local_time.to_date)

    day = workspace_working_hours_schedule.find { |entry| entry['day_of_week'].to_i == local_time.wday }
    return false if day.blank? || ActiveModel::Type::Boolean.new.cast(day['closed_all_day'])

    minute = (local_time.hour * 60) + local_time.min
    within_hours = ActiveModel::Type::Boolean.new.cast(day['open_all_day']) ||
                   minute.between?(schedule_minute(day, 'open'), schedule_minute(day, 'close'))
    return false unless within_hours

    workspace_break_schedule.none? do |entry|
      entry['days'].include?(local_time.wday) &&
        minute >= minute_for_time(entry['start_time']) && minute < minute_for_time(entry['end_time'])
    end
  end

  def sync_workspace_working_hours!
    inboxes.where(inherit_working_hours_from_account: true).find_each(&:apply_workspace_working_hours!)
    scheduling_resources.where(inherit_working_hours_from_account: true).find_each(&:apply_workspace_working_hours!)
  end

  private

  def workspace_day_off?(date)
    workspace_days_off_schedule.any? do |entry|
      configured_date = Date.iso8601(entry['date'])
      if ActiveModel::Type::Boolean.new.cast(entry['recurring_yearly'])
        configured_date.month == date.month && configured_date.day == date.day
      else
        configured_date == date
      end
    end
  end

  def schedule_minute(day, prefix)
    (day["#{prefix}_hour"].to_i * 60) + day["#{prefix}_minutes"].to_i
  end

  def minute_for_time(value)
    match = /\A([01]\d|2[0-3]):([0-5]\d)\z/.match(value.to_s)
    return if match.blank?

    (match[1].to_i * 60) + match[2].to_i
  end

  def validate_workspace_timezone
    return if workspace_timezone.blank? || TZInfo::Timezone.all_identifiers.include?(workspace_timezone)

    errors.add(:workspace_timezone, 'is not a valid timezone')
  end

  def validate_workspace_working_hours
    return if workspace_working_hours.blank?

    weekdays = Array(workspace_working_hours).filter_map do |entry|
      Integer(entry.to_h.deep_stringify_keys['day_of_week'], exception: false)
    end
    return if weekdays.sort == (0..6).to_a

    errors.add(:workspace_working_hours, 'must contain each weekday exactly once')
  end

  def validate_workspace_breaks
    return if Array(workspace_breaks).all? do |entry|
      break_entry = entry.to_h.deep_stringify_keys
      start_minute = minute_for_time(break_entry['start_time'])
      end_minute = minute_for_time(break_entry['end_time'])
      start_minute.present? && end_minute.present? && start_minute < end_minute
    end

    errors.add(:workspace_breaks, :invalid)
  end

  public :workspace_day_off?
end
