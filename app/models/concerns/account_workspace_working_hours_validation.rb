module AccountWorkspaceWorkingHoursValidation
  extend ActiveSupport::Concern

  included do
    validate :validate_workspace_timezone
    validate :validate_workspace_working_hours
    validate :validate_workspace_breaks
  end

  private

  def validate_workspace_timezone
    return if workspace_timezone.blank? || valid_workspace_timezone?(workspace_timezone)

    errors.add(:workspace_timezone, 'is not a valid timezone')
  end

  def validate_workspace_working_hours
    return if workspace_working_hours.blank?

    schedule = Array(workspace_working_hours).map { |entry| entry.to_h.deep_stringify_keys }
    weekdays = schedule.filter_map { |entry| Integer(entry['day_of_week'], exception: false) }
    unless weekdays.sort == (0..6).to_a
      errors.add(:workspace_working_hours, 'must contain each weekday exactly once')
      return
    end

    return if schedule.all? { |entry| valid_workspace_day?(entry) }

    errors.add(:workspace_working_hours, 'contains an invalid working interval')
  end

  def valid_workspace_day?(entry)
    return true if ActiveModel::Type::Boolean.new.cast(entry['closed_all_day'])
    return true if ActiveModel::Type::Boolean.new.cast(entry['open_all_day'])

    open_minute = minute_for_parts(entry, 'open')
    close_minute = minute_for_parts(entry, 'close')
    open_minute.present? && close_minute.present? && open_minute < close_minute
  end

  def minute_for_parts(entry, prefix)
    hour = Integer(entry["#{prefix}_hour"], exception: false)
    minute = Integer(entry["#{prefix}_minutes"], exception: false)
    return unless hour&.between?(0, 23) && minute&.between?(0, 59)

    (hour * 60) + minute
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
end
