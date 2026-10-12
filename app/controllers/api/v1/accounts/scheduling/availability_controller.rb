class Api::V1::Accounts::Scheduling::AvailabilityController < Api::V1::Accounts::Scheduling::BaseController
  def show
    resource = Current.account.scheduling_resources.available_for_scheduling.find(params.require(:resource_id))
    service = Current.account.scheduling_services.active.find(params[:service_id]) if params[:service_id].present?
    validate_service_link!(resource, service) if service
    from, to = requested_range(resource)
    result = Scheduling::ScheduleDayAvailabilityService.new(
      resource: resource, from: from, to: to, service: service,
      duration_min: duration_min(resource, service), cabinet_code: params[:cabinet_code],
      allow_live: !parse_boolean(params[:confirmed_only])
    ).perform

    render_payload(availability_payload(result))
  end

  private

  def availability_payload(result)
    payload = {
      windows: result.slots.map do |slot|
        { starts_at: slot.fetch(:starts_at), ends_at: slot.fetch(:ends_at), cabinet_code: slot[:cabinet_code] }.compact
      end,
      checked_at: result.checked_at&.iso8601(6), source: result.source,
      state: result.state, last_bookable_date: result.last_bookable_date&.iso8601
    }
    payload
  end

  def requested_range(resource)
    first_date, last_date = requested_dates
    raise ArgumentError, 'Date range must be 31 days or less' if (last_date - first_date).to_i >= 31

    zone = resource_time_zone(resource)
    after_last = last_date + 1
    [zone.local(first_date.year, first_date.month, first_date.day),
     zone.local(after_last.year, after_last.month, after_last.day)]
  end

  def requested_dates
    fields = params[:date].present? ? %w[date date] : %w[date_from date_to]
    dates = fields.map { |field| parse_date_param!(params.require(field), field_name: field) }
    raise ArgumentError, 'date_to must be on or after date_from' if dates.last < dates.first

    dates
  end

  def duration_min(resource, service)
    parse_duration_min_param!(params[:duration_min]) || service&.duration_min || resource.slot_duration_min
  end

  def validate_service_link!(resource, service)
    return if Scheduling::ServicePrice.active.exists?(
      account_id: Current.account.id, resource_id: resource.id, service_id: service.id
    )

    raise ArgumentError, 'Service is not available for this resource'
  end

  def resource_time_zone(resource)
    name = resource.timezone
    if Scheduling::ResourceHoursPolicy.new(resource: resource).provider_hours?
      hook = Current.account.hooks.enabled.find_by(app_id: 'medelement')
      name = Integrations::Medelement::Configuration.new(hook: hook).time_zone if hook
    end
    ActiveSupport::TimeZone[name] || Time.zone
  end
end
