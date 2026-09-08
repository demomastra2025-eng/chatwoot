class Account::WorkspaceAvailabilityPolicy
  def initialize(account:, time:)
    @account = account
    @local_time = time.in_time_zone(account.workspace_working_hours_timezone)
  end

  def open?
    return false if account.workspace_day_off?(local_time.to_date)
    return false unless working_day?
    return false unless within_working_hours?

    account.workspace_break_schedule.none? { |entry| break_covers_local_time?(entry) }
  end

  private

  attr_reader :account, :local_time

  def working_day?
    day_schedule.present? && !boolean_type.cast(day_schedule['closed_all_day'])
  end

  def within_working_hours?
    boolean_type.cast(day_schedule['open_all_day']) ||
      (local_minute >= schedule_minute('open') && local_minute < schedule_minute('close'))
  end

  def break_covers_local_time?(entry)
    entry['days'].include?(local_time.wday) &&
      local_minute >= minute_for_time(entry['start_time']) &&
      local_minute < minute_for_time(entry['end_time'])
  end

  def day_schedule
    @day_schedule ||= account.workspace_working_hours_schedule.find do |entry|
      entry['day_of_week'].to_i == local_time.wday
    end
  end

  def local_minute
    @local_minute ||= (local_time.hour * 60) + local_time.min
  end

  def schedule_minute(prefix)
    (day_schedule["#{prefix}_hour"].to_i * 60) + day_schedule["#{prefix}_minutes"].to_i
  end

  def minute_for_time(value)
    hour, minute = value.split(':').map(&:to_i)
    (hour * 60) + minute
  end

  def boolean_type
    @boolean_type ||= ActiveModel::Type::Boolean.new
  end
end
