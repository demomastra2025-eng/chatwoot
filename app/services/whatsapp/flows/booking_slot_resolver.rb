# frozen_string_literal: true

class Whatsapp::Flows::BookingSlotResolver # rubocop:disable Metrics/ClassLength
  BOOKING_HORIZON_DAYS = 14
  MAX_DROPDOWN_SLOTS = 180
  MIN_LEAD_MINUTES = 5
  WEEKDAY_KEYS = Scheduling::AvailableSlotSearchService::WEEKDAY_KEYS
  LAST_BOOKING_PATTERN = Scheduling::AvailableSlotSearchService::LAST_BOOKING_PATTERN

  def initialize(account:)
    @account = account
  end

  def timezone
    @timezone ||= begin
      tz_name = available_resources.filter_map { |res| res.timezone.presence }.first ||
                account.reporting_timezone.presence ||
                Scheduling::Constants::DEFAULT_TIMEZONE
      ActiveSupport::TimeZone[tz_name] || ActiveSupport::TimeZone[Scheduling::Constants::DEFAULT_TIMEZONE]
    end
  end

  def available_resources
    @available_resources ||= account.scheduling_resources.available_for_scheduling.ordered.to_a
  end

  def active_services
    @active_services ||= account.scheduling_services.active.order(:name, :id).to_a
  end

  def find_resource(raw_resource_id)
    return nil unless specific_resource_id?(raw_resource_id)

    id = Integer(raw_resource_id.to_s, 10, exception: false)
    return nil unless id&.positive?

    available_resources.find { |item| item.id == id }
  end

  def find_service(raw_service_id)
    return nil if raw_service_id.blank? || raw_service_id.to_s == 'none'

    id = Integer(raw_service_id.to_s, 10, exception: false)
    return nil unless id&.positive?

    active_services.find { |svc| svc.id == id }
  end

  def resource_supports_service?(resource, service)
    return true if service.blank?

    candidate_resources('any', service: service).any? { |candidate| candidate.id == resource.id }
  end

  def duration_for(resource:, service: nil)
    resolved_duration_min(resource: resource, service: service)
  end

  def candidate_resources(raw_resource_id, service: nil)
    if specific_resource_id?(raw_resource_id)
      resource = find_resource(raw_resource_id)
      return [] unless resource && resource_supports_service?(resource, service)

      return [resource]
    end
    return available_resources if service.blank?

    linked_ids = linked_resource_ids_for(service)
    return available_resources.select { |res| linked_ids.include?(res.id) } if linked_ids.present?

    unmapped_fallback_resources(service)
  end

  def upcoming_dates(days: BOOKING_HORIZON_DAYS)
    today = earliest_active_today
    (0...days).map { |offset| today + offset.days }
  end

  def parse_booking_date(raw_date)
    parsed = Scheduling::InputValidation.parse_date(raw_date)
    today = earliest_active_today
    return today if parsed.blank? || parsed < today

    parsed > (today + 60.days) ? today : parsed
  end

  def slots_for_date(resources:, date:, service: nil)
    now_cutoff = Time.current + MIN_LEAD_MINUTES.minutes
    entries = Array(resources).flat_map do |resource|
      resource_slots_on_date(resource: resource, date: date, service: service, now_cutoff: now_cutoff)
    end

    entries.sort_by! { |entry| [entry[:starts_at], entry[:resource].name.to_s, entry[:resource].id] }
    entries.first(MAX_DROPDOWN_SLOTS)
  end

  def nearest_available_date(resources:, after_date:, service: nil)
    upcoming_dates.find do |candidate_date|
      next false if candidate_date == after_date

      slots_for_date(resources: resources, date: candidate_date, service: service).any?
    end
  end

  def resolve_slot_key(slot_key, service: nil)
    resource, starts_at = parse_slot_key_parts(slot_key)
    return nil unless resource && starts_at && resource_supports_service?(resource, service)
    return nil unless within_booking_window?(resource: resource, starts_at: starts_at, enforce_lead_time: true)

    local_date = starts_at.in_time_zone(resource_zone(resource)).to_date
    slots = slots_for_date(resources: [resource], date: local_date, service: service)
    slots.find { |entry| entry[:starts_at].to_i == starts_at.to_i }
  end

  def within_booking_window?(resource:, starts_at:, enforce_lead_time: false)
    parsed = parse_slot_time(starts_at)
    return false if parsed.blank?

    min_time = enforce_lead_time ? (Time.current + MIN_LEAD_MINUTES.minutes) : Time.current
    return false if parsed <= min_time

    res_zone = resource_zone(resource)
    local_start = parsed.in_time_zone(res_zone)
    max_date = Time.current.in_time_zone(res_zone).to_date + BOOKING_HORIZON_DAYS.days
    local_start.to_date <= max_date && within_last_booking_time?(local_start)
  end

  def parse_time(raw_time)
    parse_slot_time(raw_time)
  end

  private

  attr_reader :account

  def earliest_active_today
    now = Time.current
    dates = available_resources.map { |res| now.in_time_zone(resource_zone(res)).to_date }
    dates << now.in_time_zone(timezone).to_date
    dates.min
  end

  def specific_resource_id?(raw_resource_id)
    raw_resource_id.present? && %w[any none].exclude?(raw_resource_id.to_s)
  end

  def parse_slot_key_parts(slot_key)
    resource_part, iso_part = slot_key.to_s.split('@', 2)
    return nil if resource_part.blank? || iso_part.blank?

    resource = find_resource(resource_part)
    starts_at = parse_slot_time(iso_part)
    resource && starts_at ? [resource, starts_at] : nil
  end

  def resource_zone(resource)
    ActiveSupport::TimeZone[resource.timezone.presence] ||
      ActiveSupport::TimeZone[account.reporting_timezone.presence] ||
      timezone
  end

  def resource_slots_on_date(resource:, date:, service:, now_cutoff:)
    res_zone = resource_zone(resource)
    day_start = res_zone.local(date.year, date.month, date.day, 0, 0, 0)
    raw_slots = fetch_day_slots(resource: resource, day_start: day_start, service: service)

    raw_slots.filter_map do |slot|
      build_slot_entry(resource: resource, slot: slot, res_zone: res_zone, date: date, now_cutoff: now_cutoff)
    end
  end

  def fetch_day_slots(resource:, day_start:, service:)
    availability = Scheduling::ScheduleDayAvailabilityService.new(
      resource: resource,
      from: day_start,
      to: day_start + 1.day,
      service: service,
      duration_min: resolved_duration_min(resource: resource, service: service),
      allow_live: false
    ).perform
    Array(availability.slots)
  end

  def build_slot_entry(resource:, slot:, res_zone:, date:, now_cutoff:)
    starts_at = parse_slot_time(slot[:starts_at])
    ends_at = parse_slot_time(slot[:ends_at])
    return nil unless valid_slot_window?(starts_at, ends_at, now_cutoff)

    local_start = starts_at.in_time_zone(res_zone)
    return nil unless local_start.to_date == date && within_last_booking_time?(local_start)

    {
      key: "#{resource.id}@#{starts_at.iso8601}", resource: resource,
      starts_at: starts_at, ends_at: ends_at, local_start: local_start,
      local_end: ends_at.in_time_zone(res_zone), duration_min: ((ends_at - starts_at) / 60).round,
      cabinet_code: slot[:medelement_cabinet_code] || slot[:cabinet_code]
    }
  end

  def valid_slot_window?(starts_at, ends_at, now_cutoff)
    starts_at.present? && ends_at.present? && ends_at > starts_at && starts_at > now_cutoff
  end

  def parse_slot_time(raw_time)
    return raw_time if raw_time.is_a?(Time) || raw_time.is_a?(ActiveSupport::TimeWithZone)
    return nil if raw_time.blank?

    Time.iso8601(raw_time.to_s)
  rescue ArgumentError
    Time.zone.parse(raw_time.to_s)
  end

  def resolved_duration_min(resource:, service:)
    service&.duration_min.presence || resource.slot_duration_min.presence || 30
  end

  def within_last_booking_time?(local_start)
    cutoff = last_booking_cutoff_for(local_start.wday)
    cutoff.blank? || local_start.strftime('%H:%M') <= cutoff
  end

  def last_booking_cutoff_for(wday)
    settings = account.settings.to_h
    day_cutoff = settings['scheduling_last_booking_time_by_weekday'].to_h[WEEKDAY_KEYS[wday]].to_s.strip
    return day_cutoff if day_cutoff.match?(LAST_BOOKING_PATTERN)

    global_cutoff = settings['scheduling_last_booking_time'].to_s.strip
    global_cutoff.match?(LAST_BOOKING_PATTERN) ? global_cutoff : nil
  end

  def linked_resource_ids_for(service)
    price_ids = Scheduling::ServicePrice.active.where(account_id: account.id, service_id: service.id).pluck(:resource_id)
    stat_ids = Scheduling::ResourceServiceStat.usable.where(account_id: account.id, service_id: service.id).pluck(:resource_id)
    price_ids | stat_ids
  end

  def unmapped_fallback_resources(service)
    return available_resources if service.custom_attributes.to_h['medelement_nomenclature_code'].present?

    available_resources.reject { |res| res.custom_attributes.to_h['medelement_specialist_code'].present? }
  end
end
