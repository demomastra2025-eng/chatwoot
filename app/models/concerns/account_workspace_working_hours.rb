module AccountWorkspaceWorkingHours
  extend ActiveSupport::Concern
  include AccountWorkspaceWorkingHoursValidation

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
  end

  def workspace_working_hours_enabled?
    true
  end

  def workspace_working_hours_timezone
    configured_timezone = workspace_timezone.presence
    return configured_timezone if configured_timezone && valid_workspace_timezone?(configured_timezone)

    DEFAULT_TIMEZONE
  end

  def workspace_working_hours_schedule
    schedule = workspace_working_hours
    return DEFAULT_SCHEDULE.deep_dup unless schedule.is_a?(Array) && schedule.size == 7

    schedule.map(&:deep_stringify_keys)
  end

  def workspace_working_hours_configured?
    workspace_working_hours.is_a?(Array) && workspace_working_hours.size == 7
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
    return true unless workspace_working_hours_configured?

    Account::WorkspaceAvailabilityPolicy.new(account: self, time: time).open?
  end

  def sync_workspace_working_hours!
    scheduling_resources.find_each(&:sync_workspace_schedule!)
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

  def minute_for_time(value)
    match = /\A([01]\d|2[0-3]):([0-5]\d)\z/.match(value.to_s)
    return if match.blank?

    (match[1].to_i * 60) + match[2].to_i
  end

  def valid_workspace_timezone?(timezone)
    TZInfo::Timezone.all_identifiers.include?(timezone)
  end

  public :workspace_day_off?
end
