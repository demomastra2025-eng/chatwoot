class Captain::Tools::Copilot::GetSchedulingResourceAvailabilityService < Captain::Tools::Copilot::BaseAccountTool
  include Captain::Tools::Copilot::SchedulingQueryValidation
  MAX_RANGE_DAYS = Scheduling::RangeValidator::MAX_RANGE_DAYS

  def self.name
    'get_scheduling_resource_availability'
  end

  description 'Get free windows of one resource from confirmed MedElement schedule days when integrated. Creation checks live again'
  param :resource_id, type: :number, desc: 'Scheduling resource ID (specialist or diagnostic resource)', required: true
  param :from, type: :string, desc: 'Range start datetime', required: true
  param :to, type: :string, desc: 'Range end datetime', required: true
  param :service_id, type: :number,
                     desc: 'Optional service ID to derive duration using a recorded price link, not provider eligibility', required: false
  param :duration_min, type: :number, desc: 'Optional appointment duration in minutes', required: false
  param :limit, type: :number, desc: 'Maximum number of slots to return', required: false

  def execute(resource_id:, from:, to:, service_id: nil, duration_min: nil, limit: nil)
    service_id = scheduling_service_id(service_id)
    range_from = scheduling_datetime(from, field_name: 'from')
    range_to = scheduling_datetime(to, field_name: 'to')
    scheduling_range!(range_from, range_to)

    resource = find_resource!(resource_id)
    service_record = resolve_service_for_resource(resource: resource, service_id: service_id)
    payload = availability_payload(resource, service_record, service_id, range_from, range_to, duration_min, limit)

    formatted_payload(with_provider_note(resource, range_from, range_to, payload.merge(availability_metadata(resource, service_record))))
  rescue StandardError => e
    scheduling_tool_failure(e)
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end

  private

  def availability_payload(resource, service_record, service_id, range_from, range_to, duration_min, limit)
    if Scheduling::ResourceHoursPolicy.new(resource: resource).provider_hours?
      payload = Scheduling::AvailableSlotSearchService.new(
        account: account, from: range_from, to: range_to, resource_ids: [resource.id],
        service_id: service_id, duration_min: duration_min, limit: parse_limit(limit)
      ).perform
      return payload.merge(resource: Scheduling::PayloadBuilder.resource(resource), timezone: resource.timezone,
                           duration_min: payload[:duration_min] || resource.slot_duration_min)
    end

    Scheduling::ResourceAvailabilityQueryService.new(
      resource: resource, from: range_from, to: range_to, service: service_record,
      duration_min: duration_min, limit: parse_limit(limit)
    ).perform
  end

  def with_provider_note(resource, range_from, range_to, payload)
    note = provider_note(resource, range_from, range_to)
    payload[:provider_schedule_note] = note if note
    payload
  end

  def provider_note(resource, range_from, range_to)
    from_date = range_from.in_time_zone(resource.timezone).to_date
    to_date = (range_to - 1.second).in_time_zone(resource.timezone).to_date
    return unless from_date == to_date

    Integrations::Medelement::ProviderScheduleNote.for(resource: resource, date: from_date)
  end

  def availability_metadata(resource, service_record)
    provider_required = Scheduling::AvailableSlotSearchService.provider_related?(resource)
    link_status = if service_record.blank?
                    'not_requested'
                  elsif provider_required
                    'price_link_unverified'
                  else
                    'local_configured'
                  end
    { availability_source: provider_required ? 'medelement' : 'local_rules',
      provider_checked: false,
      provider_required: provider_required, service_link_status: link_status }
  end

  def find_resource!(resource_id)
    account.scheduling_resources.available_for_scheduling.find_by(id: resource_id).tap do |resource|
      if resource.blank?
        raise Scheduling::Error.new(code: 'RESOURCE_NOT_FOUND', message: 'Scheduling resource not found', status: :not_found,
                                    details: { reason: 'unknown_resource' })
      end
    end
  end

  def resolve_service_for_resource(resource:, service_id:)
    return nil if service_id.blank?

    service_record = scheduling_service!(service_id)

    active_price = resource.service_prices.active.find_by(account_id: account.id, service_id: service_record.id)
    if active_price.blank?
      raise Scheduling::Error.new(code: 'SERVICE_NOT_AVAILABLE_FOR_RESOURCE',
                                  message: 'No recorded service-price link for this resource; provider eligibility is unverified',
                                  status: :unprocessable_content, details: { reason: 'service_not_linked' })
    end

    service_record
  end
end
