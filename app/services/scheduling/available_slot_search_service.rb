class Scheduling::AvailableSlotSearchService
  MAX_LIMIT = 100
  # The keys of scheduling_last_booking_time_by_weekday, indexed by Time#wday.
  WEEKDAY_KEYS = %w[sun mon tue wed thu fri sat].freeze
  LAST_BOOKING_PATTERN = /\A([01]\d|2[0-3]):[0-5]\d\z/
  MAX_RANGE_DAYS = Scheduling::RangeValidator::MAX_RANGE_DAYS
  # A search for a service with no specialist named, when no available specialist is recorded for that service (neither a price
  # link nor a pair of the visit history, see Scheduling::ResourceServiceStat). Searching every specialist instead would offer the
  # slot of a doctor who does not perform the service, so the caller must choose the specialist first (search_scheduling_resources)
  # and search again with resource_ids.
  class ResourceSelectionRequiredError < ArgumentError; end
  RESOURCE_SELECTION_REQUIRED_ERROR = 'No specialist is recorded for this service, so the search needs resource_ids'.freeze

  def self.provider_related?(resource)
    attrs = resource.custom_attributes.to_h
    attrs['medelement_specialist_code'].present? || attrs['medelement_cabinets'].present?
  end

  INVALID_RESOURCE_IDS_MESSAGE = 'resource_ids takes specialist IDs from search_scheduling_resources'.freeze

  # The specialist ids to search. A blank value, null and 0 mean no specialist and are dropped, so the search covers the others.
  # Anything else that is not a positive integer (a doctor's name) is an error: dropping it would widen the search to every
  # specialist and offer the slot of another doctor as the answer for the one asked for.
  def self.normalize_resource_ids(value)
    values = value.is_a?(String) ? value.split(',') : Array(value)
    values.filter_map { |item| normalize_resource_id(item) }.uniq
  end

  def self.normalize_resource_id(item)
    return if item.blank? || Scheduling::IntegerNumericNormalizer.normalize_value(item)&.zero?

    Scheduling::IntegerNumericNormalizer.optional_positive_id(item) || raise(
      Scheduling::Error.new(code: 'INVALID_RESOURCE_IDS', message: INVALID_RESOURCE_IDS_MESSAGE, status: :unprocessable_content,
                            details: { field: 'resource_ids', reason: 'invalid_resource_ids' })
    )
  end
  private_class_method :normalize_resource_id

  # `to` is the latest start of a visit. The schedule is read up to the end of a visit that starts just before `to` (and, for a
  # window shorter than one visit, of a visit that starts at `from`), so a one-minute window (11:00-11:01) finds the visit at 11:00
  # when it is free, and a start at 11:30 is found for the window 11:00-12:00.
  def initialize(account:, from:, to:, resource_ids: nil, service_id: nil, duration_min: nil, limit: nil, snapshots: nil)
    @account = account
    @from = from
    @to = to
    @resource_ids = self.class.normalize_resource_ids(resource_ids)
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
      service: service.present? ? Scheduling::VisitDuration.service_payload(service, duration_min: top_level_duration_min) : nil,
      duration_min: top_level_duration_min,
      resources: resources.map { |resource| Scheduling::PayloadBuilder.resource(resource) },
      slots: normalized_slots,
      total_slots: normalized_slots.length,
      slot_count_scope: 'returned_only',
      availability: availability_payload,
      availability_note: availability_note,
      last_booking_time: last_booking_time,
      last_booking_time_by_weekday: last_booking_time_by_weekday.presence
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
      # Requested specialists are searched with the service whether or not a price link records it: a link is never required.
      scope = @account.scheduling_resources.available_for_scheduling
      scope = scope.where(id: @resource_ids) if @resource_ids.present?
      scope = scope.where(id: service_resource_ids) if service.present? && @resource_ids.blank?
      resolved = scope.ordered.to_a

      if @resource_ids.present?
        missing_ids = @resource_ids - resolved.map(&:id)
        raise ActiveRecord::RecordNotFound, "Specialists not found: #{missing_ids.join(', ')}" if missing_ids.present?
      end
      ensure_resource_selected!(resolved)

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
    if service.present? && @resource_ids.blank?
      linked_ids = @snapshots.linked_resource_ids(service.id) |
                   Scheduling::ResourceServiceStat.usable.where(account_id: @account.id, service_id: service.id).pluck(:resource_id)
      resolved = resolved.select { |resource| linked_ids.include?(resource.id) }
    end
    resolved
  end

  def active_price_links
    Scheduling::ServicePrice.active.where(account_id: @account.id, service_id: service.id)
  end

  # The specialists of a service searched without a specialist named: the ones with an active price link and the ones whose visit
  # history carries the service (an auto or confirmed pair). A disabled or stale pair does not count.
  def service_resource_ids
    history = Scheduling::ResourceServiceStat.usable.where(account_id: @account.id, service_id: service.id)
    Scheduling::Resource.where(id: active_price_links.select(:resource_id)).or(Scheduling::Resource.where(id: history.select(:resource_id)))
                        .select(:id)
  end

  # With a service and no specialist named, the specialists are the ones recorded for the service. When none of them can be
  # booked (the service has no link at all), the search stops instead of searching every specialist.
  def ensure_resource_selected!(resolved)
    return if service.blank? || @resource_ids.present? || resolved.present?

    raise ResourceSelectionRequiredError, RESOURCE_SELECTION_REQUIRED_ERROR
  end

  def linked_resource_ids
    return [] if service.blank?

    @linked_resource_ids ||= active_price_links.where(resource_id: resources.map(&:id)).distinct.pluck(:resource_id)
  end

  # True when the service was requested and a searched specialist has no recorded link to it: the slots are still offered,
  # only the match of the service and the specialist is not confirmed by a link.
  def unlinked_service_fallback?
    @service_id.present? && service.present? && resources.present? && (resources.map(&:id) - linked_resource_ids).any?
  end

  def normalized_slots
    @normalized_slots ||= begin
      slots = resources.flat_map do |resource|
        provider_checked_slots(resource)
      end
      slots.sort_by { |slot| Time.zone.parse(slot[:starts_at]) }.first(@limit)
    end
  end

  def local_slots(resource, from: @from, to: query_to(resource), provider_working_windows: nil, uncapped: false)
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
      duration_min: visit_duration(resource),
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
      eligibility = linked_resource_ids.include?(resource.id) ? 'local_configured' : 'price_link_unverified'
      return label_service_eligibility(starting_in_window(local_slots(resource)), eligibility)
    end

    integrated_slots(resource)
  end

  # The range the schedule is read for: up to `to` plus one visit, because a visit that starts just before `to` ends after it and
  # a slot exists only when the whole visit fits (starting_in_window then drops the starts at or after `to`). The range never
  # grows past the days the schedule readers accept, and never ends before `to`.
  def query_to(resource)
    visit = [visit_duration(resource), Scheduling::Constants::MIN_DURATION_MINUTES].max.minutes
    horizon = @from + MAX_RANGE_DAYS.days
    horizon > @to ? [@to + visit, horizon].min : @to
  end

  # Only starts before `to` are offered; a start at `from` counts even when `to` is equal to `from` (an exact-time check). A start
  # after the clinic's last booking time is never offered (see #last_booking_time).
  def starting_in_window(slots)
    from_at = @from.to_i
    to_at = @to.to_i
    slots.select do |slot|
      starts_at = Time.zone.parse(slot[:starts_at]).to_i
      starts_at >= from_at && (starts_at < to_at || starts_at == from_at) && before_last_booking?(slot)
    end
  end

  # The latest local start of a visit the clinic takes ("19:00", the account setting scheduling_last_booking_time), or nil. The
  # schedule of a doctor may show later free starts (19:30, 19:50) that the clinic does not book.
  def last_booking_time
    return @last_booking_time if defined?(@last_booking_time)

    @last_booking_time = valid_last_booking_time(@account.settings.to_h['scheduling_last_booking_time'])
  end

  # The latest start of a weekday that differs from last_booking_time, { 'sat' => '13:40', 'sun' => '14:00' } (the account setting
  # scheduling_last_booking_time_by_weekday, keys sun mon tue wed thu fri sat). A weekday with a null value has no limit; a weekday
  # that is not listed keeps last_booking_time. A clinic that books later on weekdays than on Saturday needs both: the eval of
  # 26.10 offered 14:40 on a Saturday of a branch whose last booking is 13:40 on Saturdays.
  def last_booking_time_by_weekday
    @last_booking_time_by_weekday ||= begin
      configured = @account.settings.to_h['scheduling_last_booking_time_by_weekday']
      configured = {} unless configured.is_a?(Hash)
      configured.stringify_keys.slice(*WEEKDAY_KEYS).select { |_day, value| value.nil? || valid_last_booking_time(value) }
    end
  end

  def valid_last_booking_time(value)
    value = value.to_s
    value if value.match?(LAST_BOOKING_PATTERN)
  end

  # The start in the local time of the slot (its ISO offset is the time zone of the specialist), against the limit of its weekday.
  def before_last_booking?(slot)
    return true if last_booking_time.nil? && last_booking_time_by_weekday.empty?

    start = Time.iso8601(slot[:starts_at].to_s)
    limit = last_booking_time_by_weekday.fetch(WEEKDAY_KEYS[start.wday], last_booking_time)
    limit.nil? || start.strftime('%H:%M') <= limit
  rescue ArgumentError
    true
  end

  def integrated_slots(resource)
    range = Scheduling::ResourceHoursPolicy.new(resource: resource).clipped_range(from: @from, to: query_to(resource))
    return [] if range.nil?

    result = Scheduling::ScheduleDayAvailabilityService.new(
      resource: resource, from: range.first, to: range.last,
      service: service, duration_min: visit_duration(resource)
    ).perform
    record_availability(
      resource_id: resource.id,
      provider: 'medelement',
      status: result.state == 'ok' ? 'fresh' : result.state,
      checked_at: result.checked_at&.iso8601(6)
    )
    slots = starting_in_window(result.slots).first(@limit).map do |slot|
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

    # A price question still has its answer (the eval of 26.10: an agent handed a catalog price to staff because of this note).
    'Не удалось проверить график MedElement; наличие свободного времени неизвестно. Цены и описание услуг ' \
      '(search_scheduling_services) от графика не зависят: их можно назвать.'
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
    return 'price_link_unverified' if resources.any? { |resource| provider_related?(resource) } || unlinked_service_fallback?

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
    @service_id.present? && service.present? && resources.present? &&
      resources.none? { |resource| provider_related?(resource) } && !unlinked_service_fallback?
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

  # The length of the visit at this specialist: the requested minutes, else the service's, else the specialist's slot. For a MedElement
  # service it is the median length of the specialist's visits with it (see Scheduling::VisitDuration).
  def visit_duration(resource)
    Scheduling::ResourceAvailabilityQueryService.duration_for(resource: resource, service: service, duration_min: @requested_duration_min,
                                                              stats: duration_stats)
  end

  def duration_stats
    @duration_stats ||= Scheduling::VisitDuration.stats_for(service: service, resource_ids: resources.map(&:id))
  end

  # One length for the whole answer, when the searched specialists share it; otherwise none (each slot carries its own duration_min).
  def top_level_duration_min
    return @requested_duration_min.presence if service.blank?
    return service.duration_min if @snapshots

    resources.map { |resource| visit_duration(resource) }.uniq.then { |durations| durations.first if durations.one? }
  end

  def normalize_limit(value)
    numeric = value.to_i
    return MAX_LIMIT if numeric <= 0

    [numeric, MAX_LIMIT].min
  end

  def validate_range!
    Scheduling::RangeValidator.validate!(from: @from, to: @to, max_days: MAX_RANGE_DAYS, allow_equal: true)
  end
end
