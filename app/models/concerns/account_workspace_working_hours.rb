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
    store_accessor :settings, :workspace_working_hours_enabled, :workspace_timezone, :workspace_working_hours
    validate :validate_workspace_timezone
  end

  def workspace_working_hours_enabled?
    ActiveModel::Type::Boolean.new.cast(workspace_working_hours_enabled)
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
    settings.key?('workspace_working_hours')
  end

  def sync_workspace_working_hours!
    inboxes.where(inherit_working_hours_from_account: true).find_each(&:apply_workspace_working_hours!)
  end

  private

  def validate_workspace_timezone
    return if workspace_timezone.blank? || TZInfo::Timezone.all_identifiers.include?(workspace_timezone)

    errors.add(:workspace_timezone, 'is not a valid timezone')
  end
end
