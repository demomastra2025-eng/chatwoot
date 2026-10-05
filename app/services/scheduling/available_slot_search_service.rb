class Scheduling::AvailableSlotSearchService
  MAX_LIMIT = 100
  MAX_RANGE_DAYS = Scheduling::RangeValidator::MAX_RANGE_DAYS
  # Kept identical to the message pinned by the MedElement contract specs; the tool adds the explanation.
  MISSING_LINK_ERROR = 'Service is not available for the requested specialists'.freeze

  class MissingServiceLinkError < ArgumentError; end

  def self.provider_related?(resource)
    attrs = resource.custom_attributes.to_h
    attrs['medelement_specialist_code'].present? || attrs['medelement_cabinets'].present?
  end

  def initialize(account:, from:, to:, resource_ids: nil, service_id: nil, duration_min: nil, limit: nil)
    @account = account
    @from = from
    @to = to
    @resource_ids = Array(resource_ids).compact_blank.map(&:to_i)
    @service_id = Scheduling::IntegerNumericNormalizer.optional_positive_id(service_id)
    @requested_duration_min = duration_min.presence&.to_i
    @limit = normalize_limit(limit)
  end

  def perform
    validate_range!

    payload = {
      range: {
        from: @from.iso8601,
        to: @to.iso8601
      },
      service: service.present? ? Scheduling::PayloadBuilder.service(service) : nil,
      duration_min: top_level_duration_min,
      resources: resources.map { |resource| Scheduling::PayloadBuilder.resource(resource) },
      slots: normalized_slots,
      total_slots: normalized_slots.length,
      slot_count_scope: 'returned_only',
      availability: availability_payload
    }.compact
    payload.merge(availability_scope_payload)
  end

  private

  def service
    @service ||= @service_id.present? ? @account.scheduling_services.active.find(@service_id) : nil
  end

  def resources
    @resources ||= begin
      scope = @account.scheduling_resources.available_for_scheduling
      scope = scope.where(id: @resource_ids) if @resource_ids.present?
      resolved = scope.ordered.to_a

      if @resource_ids.present?
        missing_ids = @resource_ids - resolved.map(&:id)
        raise ActiveRecord::RecordNotFound, "Specialists not found: #{missing_ids.join(', ')}" if missing_ids.present?
      end

      if service.present?
        eligible_resource_ids = Scheduling::ServicePrice.active.where(account_id: @account.id, service_id: service.id).distinct.pluck(:resource_id)

        if @resource_ids.present?
          unsupported_ids = resolved.map(&:id) - eligible_resource_ids
          raise MissingServiceLinkError, MISSING_LINK_ERROR if unsupported_ids.present?
        end

        resolved = resolved.select { |resource| eligible_resource_ids.include?(resource.id) }
      end

      resolved
    end
  end

  def normalized_slots
    @normalized_slots ||= begin
      slots = resources.flat_map do |resource|
        provider_checked_slots(resource, local_slots(resource))
      end
      slots.sort_by { |slot| Time.zone.parse(slot[:starts_at]) }.first(@limit)
    end
  end

  def local_slots(resource)
    payload = Scheduling::ResourceAvailabilityQueryService.new(
      resource: resource,
      from: @from,
      to: @to,
      service: service,
      duration_min: @requested_duration_min,
      limit: @limit
    ).perform
    payload.fetch(:slots, []).map do |slot|
      slot.merge(resource_name: resource.name, timezone: resource.timezone, availability_source: 'local')
    end
  end

  def provider_checked_slots(resource, local_slots)
    return unverified_provider_route_slots(resource) if provider_route_missing?(resource)

    unless medelement_resource?(resource)
      record_availability(resource_id: resource.id, status: 'local_only')
      return label_service_eligibility(local_slots, 'local_configured')
    end

    result = Integrations::Medelement::ResourceAvailabilityService.new(
      resource: resource,
      from: @from,
      to: @to,
      slots: local_slots
    ).perform
    record_availability(
      resource_id: resource.id,
      provider: 'medelement',
      status: result.status,
      checked_at: result.checked_at.iso8601(6),
      reason: result.reason
    )
    label_service_eligibility(result.slots, 'price_link_unverified')
  end

  def label_service_eligibility(slots, status)
    return slots if @service_id.blank?

    slots.map { |slot| slot.merge(service_eligibility_status: status) }
  end

  def unverified_provider_route_slots(resource)
    record_availability(resource_id: resource.id, provider: 'medelement', status: 'unavailable',
                        reason: 'provider_resource_route_unverified')
    []
  end

  def record_availability(attributes)
    availability_resources << attributes.compact
  end

  def availability_payload
    normalized_slots
    statuses = availability_resources.pluck(:status)
    status = if statuses.include?('unavailable')
               'degraded'
             elsif statuses.include?('fresh')
               'fresh'
             else
               'local_only'
             end

    { status: status, resources: availability_resources }
  end

  def availability_resources
    @availability_resources ||= []
  end

  def availability_scope_payload
    confirmed = service_match_confirmed?
    {
      availability_scope: availability_scope(confirmed),
      requested_service_id: @service_id,
      service_link_status: service_link_status,
      candidate_resource_ids: resources.map(&:id),
      service_match: service_match_payload(confirmed),
      customer_offer_eligible: confirmed && normalized_slots.present?
    }
  end

  def service_link_status
    return 'not_requested' if @service_id.blank?
    return 'no_recorded_link' if resources.blank?
    return 'price_link_unverified' if resources.any? { |resource| provider_related?(resource) }

    'local_configured'
  end

  def service_match_payload(confirmed)
    {
      confirmed: confirmed,
      service_id: confirmed ? service.id : nil,
      resource_id: confirmed && resources.one? ? resources.first.id : nil,
      resource_ids: confirmed ? resources.map(&:id) : []
    }
  end

  def availability_scope(confirmed)
    return 'generic' if @service_id.blank?

    confirmed ? 'service_confirmed' : 'service_unconfirmed'
  end

  def service_match_confirmed?
    @service_id.present? && service.present? && resources.present? && resources.none? { |resource| provider_related?(resource) }
  end

  def medelement_resource?(resource)
    resource.custom_attributes.to_h['medelement_specialist_code'].present?
  end

  def provider_related?(resource)
    self.class.provider_related?(resource)
  end

  def provider_route_missing?(resource)
    provider_related?(resource) && !medelement_resource?(resource)
  end

  def top_level_duration_min
    return service.duration_min if service.present?

    @requested_duration_min.presence
  end

  def normalize_limit(value)
    numeric = value.to_i
    return MAX_LIMIT if numeric <= 0

    [numeric, MAX_LIMIT].min
  end

  def validate_range!
    Scheduling::RangeValidator.validate!(from: @from, to: @to, max_days: MAX_RANGE_DAYS)
  end
end
