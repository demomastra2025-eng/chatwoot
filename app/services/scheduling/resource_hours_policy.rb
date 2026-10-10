class Scheduling::ResourceHoursPolicy
  HORIZON_DAYS = 90
  HORIZON_CODE = 'MEDELEMENT_HORIZON_EXCEEDED'.freeze

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
    return [from, to] unless provider_hours?

    clipped_from = [from, first_day_start].max
    clipped_to = [to, horizon_end].min
    return if clipped_to <= clipped_from

    [clipped_from, clipped_to]
  end

  def validate_booking!(starts_at:, ends_at:)
    return unless provider_hours?

    if starts_at < first_day_start
      raise Scheduling::Error.new(
        code: 'OUTSIDE_WORKING_HOURS', message: 'Запись на прошедшую дату невозможна.', status: :unprocessable_content
      )
    end
    return if starts_at < horizon_end && ends_at <= horizon_end

    raise Scheduling::Error.new(
      code: HORIZON_CODE,
      message: horizon_message,
      status: :unprocessable_content
    )
  end

  def horizon_message
    "График врача открыт до #{last_date.strftime('%d.%m.%Y')}. Запись на более позднюю дату пока невозможна."
  end

  def last_date
    today + (HORIZON_DAYS - 1)
  end

  private

  def today
    @today ||= Time.current.in_time_zone(time_zone).to_date
  end

  def first_day_start
    time_zone.local(today.year, today.month, today.day)
  end

  def horizon_end
    date = last_date + 1
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
