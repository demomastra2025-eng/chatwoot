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

  def initialize(account:, from:, to:, resource_ids: nil, service_id: nil, duration_min: nil, limit: nil, snapshots: nil)
    @account = account
    @from = from
    @to = to
    @resource_ids = Array(resource_ids).compact_blank.map(&:to_i)
    @service_id = Scheduling::IntegerNumericNormalizer.optional_positive_id(service_id)
    @requested_duration_min = duration_min.presence&.to_i
    @limit = normalize_limit(limit)
    @snapshots = snapshots
  end

  def perform
    validate_range!

    payload = {
      range: {
        from: @from.iso8601,
        to: @to.iso8601
      },
      service: service.present? ? Scheduling::PayloadBuilder.service(service, prices: []) : nil,
      duration_min: top_level_duration_min,
      resources: resources.map { |resource| Scheduling::PayloadBuilder.resource(resource) },
      slots: normalized_slots,
      total_slots: normalized_slots.length,
      slot_count_scope: 'returned_only',
      availability: availability_payload,
      availability_note: availability_note
    }.compact
    payload.merge(availability_scope_payload)
  end

  private

  def service
    return @snapshots.service(@service_id) if @snapshots

    @service ||= @service_id.present? ? @account.scheduling_services.active.find(@service_id) : nil
  end

  def resources
    return @resources ||= snapshot_resources if @snapshots

    @resources ||= begin
      scope = @account.scheduling_resources.available_for_scheduling
      scope = scope.where(id: @resource_ids) if @resource_ids.present?
      scope = scope.where(id: active_price_links.select(:resource_id)) if service.present? && @resource_ids.blank?
      resolved = scope.ordered.to_a

      if @resource_ids.present?
        missing_ids = @resource_ids - resolved.map(&:id)
        raise ActiveRecord::RecordNotFound, "Specialists not found: #{missing_ids.join(', ')}" if missing_ids.present?
      end

      verify_requested_links!(resolved) if service.present? && @resource_ids.present?

      resolved
    end
  end

  def snapshot_resources
    resolved = @snapshots.resources
    resolved = resolved.select { |resource| @resource_ids.include?(resource.id) } if @resource_ids.present?
    if @resource_ids.present?
      missing_ids = @resource_ids - resolved.map(&:id)
      raise ActiveRecord::RecordNotFound, "Specialists not found: #{missing_ids.join(', ')}" if missing_ids.present?
    end
    if service.present?
      linked_ids = @snapshots.linked_resource_ids(service.id)
      raise MissingServiceLinkError, MISSING_LINK_ERROR if @resource_ids.present? && (resolved.map(&:id) - linked_ids).present?

      resolved = resolved.select { |resource| linked_ids.include?(resource.id) }
    end
    resolved
  end

  def active_price_links
    Scheduling::ServicePrice.active.where(account_id: @account.id, service_id: service.id)
  end

  def verify_requested_links!(resolved)
    linked_ids = active_price_links.where(resource_id: resolved.map(&:id)).distinct.pluck(:resource_id)
    raise MissingServiceLinkError, MISSING_LINK_ERROR if (resolved.map(&:id) - linked_ids).present?
  end

  def normalized_slots
    @normalized_slots ||= begin
      slots = resources.flat_map do |resource|
        provider_checked_slots(resource)
      end
      slots.sort_by { |slot| Time.zone.parse(slot[:starts_at]) }.first(@limit)
    end
  end

  def local_slots(resource, from: @from, to: @to, provider_working_windows: nil, uncapped: false)
    if @snapshots
      return @snapshots.availability(resource: resource, from: from, to: to, service: service, duration_min: @requested_duration_min,
                                     limit: @limit, uncapped: uncapped).fetch(:slots).map do |slot|
        slot.merge(resource_name: resource.name, timezone: resource.timezone, availability_source: 'local')
      end
    end

    policy = Scheduling::ResourceHoursPolicy.new(resource: resource)
    payload = Scheduling::ResourceAvailabilityQueryService.new(
      resource: resource,
      from: from,
      to: to,
      service: service,
      duration_min: @requested_duration_min,
      limit: @limit,
      **policy.availability_options(provider_working_windows),
      uncapped: uncapped
    ).perform
    payload.fetch(:slots, []).map do |slot|
      slot.merge(resource_name: resource.name, timezone: resource.timezone, availability_source: 'local')
    end
  end

  def provider_checked_slots(resource)
    return unverified_provider_route_slots(resource) if provider_route_missing?(resource)

    unless medelement_resource?(resource)
      record_availability(resource_id: resource.id, status: 'local_only')
      return label_service_eligibility(local_slots(resource), 'local_configured')
    end

    integrated_slots(resource)
  end

  def integrated_slots(resource)
    range = Scheduling::ResourceHoursPolicy.new(resource: resource).clipped_range(from: @from, to: @to)
    return [] if range.nil?

    result = Scheduling::ScheduleDayAvailabilityService.new(
      resource: resource, from: range.first, to: range.last,
      service: service, duration_min: @requested_duration_min
    ).perform
    record_availability(
      resource_id: resource.id,
      provider: 'medelement',
      status: result.state == 'ok' ? 'fresh' : result.state,
      checked_at: result.checked_at&.iso8601(6)
    )
    slots = result.slots.first(@limit).map do |slot|
      slot.merge(resource_name: resource.name, timezone: resource.timezone,
                 availability_source: 'medelement', medelement_cabinet_code: slot[:cabinet_code])
    end
    label_service_eligibility(slots, 'price_link_unverified')
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
    status = if statuses.intersect?(%w[unavailable schedule_not_confirmed provider_unavailable internal_failure])
               'degraded'
             elsif statuses.intersect?(%w[fresh closed_day])
               'fresh'
             else
               'local_only'
             end

    code = if statuses.include?('internal_failure')
             'INTERNAL_FAILURE'
           elsif statuses.intersect?(%w[unavailable provider_unavailable])
             'PROVIDER_UNAVAILABLE'
           elsif statuses.include?('schedule_not_confirmed')
             'SCHEDULE_NOT_CONFIRMED'
           end
    { status: status, resources: availability_resources, code: code, reason: code&.downcase }.compact
  end

  def availability_note
    return unless availability_payload[:status] == 'degraded'

    'Не удалось проверить график MedElement; наличие свободного времени неизвестно.'
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
      service_match: service_match_payload(confirmed)
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
