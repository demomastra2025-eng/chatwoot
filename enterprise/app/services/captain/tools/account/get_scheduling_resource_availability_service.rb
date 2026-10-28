class Captain::Tools::Account::GetSchedulingResourceAvailabilityService < Captain::Tools::Account::BaseAccountTool
  include Captain::Tools::Account::SchedulingQueryValidation
  include Captain::Tools::Account::AgentTimeRange
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
    service_record = scheduling_service!(service_id)
    # In a patient conversation the free windows start now; a range that ended before now is not read.
    present = present_range(range_from, range_to)
    return formatted_payload(passed_range_payload(resource)) unless present

    range_from, range_to = present
    payload = availability_payload(resource, service_record, service_id, range_from, range_to, duration_min, limit)
    payload = named_slots(payload, resource) if agent_scope?
    absences = Scheduling::TimeOffPayload.for(account: account, resource_ids: [resource.id], from: range_from, to: range_to)
    payload[:absences] = absences if absences.any?

    formatted_payload(with_provider_note(resource, range_from, range_to, payload.merge(availability_metadata(resource, service_record))))
  rescue StandardError => e
    scheduling_tool_failure(e)
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end

  private

  # In a patient conversation every slot carries the name of its specialist, as a day of search_available_slots does: a time is never
  # read without whose it is (the eval of 27.10: the times of one specialist were given under the name of another).
  def named_slots(payload, resource)
    return payload unless payload[:slots].is_a?(Array)

    payload.merge(slots: payload[:slots].map { |slot| slot.is_a?(Hash) ? { resource_name: resource.name }.merge(slot) : slot })
  end

  def passed_range_payload(resource)
    { resource: Scheduling::PayloadBuilder.resource(resource), timezone: resource.timezone, slots: [], total_slots: 0,
      requested_range_status: RANGE_PASSED_STATUS, requested_range_note: range_passed_note('from now, found with search_available_slots.') }
  end

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

  # The service only sets the visit length: a recorded service-price link to the resource is never required, and
  # service_link_status only says whether one exists.
  def availability_metadata(resource, service_record)
    provider_required = Scheduling::AvailableSlotSearchService.provider_related?(resource)
    has_active_link = service_record.present? &&
                      resource.service_prices.active.exists?(account_id: account.id, service_id: service_record.id)
    link_status = if service_record.blank?
                    'not_requested'
                  elsif provider_required || !has_active_link
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
end
