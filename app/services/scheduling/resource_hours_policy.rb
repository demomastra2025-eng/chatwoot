class Scheduling::ResourceHoursPolicy
  def initialize(resource:)
    @resource = resource
  end

  def provider_hours?
    @resource.custom_attributes.to_h['medelement_specialist_code'].present?
  end

  def availability_options(windows)
    return {} unless provider_hours?

    { provider_working_windows: windows, replace_work_rules: true }
  end

  def clipped_range(from:, to:)
    return if to <= from

    [from, to]
  end

  # This is the background sync's cache window, not a booking permission.
  # Dates outside it require a confirmed on-demand provider read.
  def cached_range?(from:, to:)
    from >= first_day_start && to <= cache_end
  end

  private

  def today
    @today ||= Time.current.in_time_zone(time_zone).to_date
  end

  def first_day_start
    time_zone.local(today.year, today.month, today.day)
  end

  def cache_end
    date = today + Integrations::Medelement::SchedulesSyncService::SCHEDULE_HORIZON_DAYS
    time_zone.local(date.year, date.month, date.day)
  end

  def time_zone
    @time_zone ||= begin
      hook = @resource.account.hooks.find_by(app_id: 'medelement')
      name = hook ? Integrations::Medelement::Configuration.new(hook: hook).time_zone : @resource.timezone
      ActiveSupport::TimeZone[name] || Time.zone
    end
  end
end
