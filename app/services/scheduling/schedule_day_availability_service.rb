class Scheduling::ScheduleDayAvailabilityService
  Result = Data.define(:slots, :state, :checked_at, :source, :last_bookable_date)

  # The sync refreshes days 0-1 hourly, days 2-13 every 12 hours and later days daily.
  FRESHNESS_MARGIN_MINUTES = [Integer(ENV.fetch('MEDELEMENT_SCHEDULE_FRESHNESS_MARGIN_MINUTES', 15), exception: false) || 15, 0].max

  def initialize(resource:, from:, to:, **options)
    @resource = resource
    @from = from
    @to = to
    @service = options[:service]
    @duration_min = options[:duration_min]
    @cabinet_code = options[:cabinet_code].to_s.presence
    @allow_live = options.fetch(:allow_live, true)
  end

  def perform
    policy = Scheduling::ResourceHoursPolicy.new(resource: @resource)
    return local_result unless policy.provider_hours?

    provider_result(policy)
  end

  private

  def provider_result(policy)
    range = policy.clipped_range(from: @from, to: @to)
    return result([], 'schedule_not_confirmed', nil) unless range
    return result([], 'provider_unavailable', nil) unless hook&.feature_allowed? && cabinets.present?

    days = schedule_days(range.first, range.last)
    cached = policy.cached_range?(from: range.first, to: range.last)
    confirmed = days.all? { |day| fresh?(day) && day.status.in?(%w[confirmed empty_confirmed]) }
    return provider_days_result(range, days) if !@allow_live || cached || confirmed

    live_provider_result(range)
  end

  def provider_days_result(range, days)
    usable = days.select { |day| fresh?(day) && day.status == 'confirmed' }
    checked_at = days.select { |day| fresh?(day) && day.status.in?(%w[confirmed empty_confirmed]) }
                     .filter_map(&:source_checked_at).min
    result(slots_for(usable, range), state_for(days), checked_at)
  end

  def state_for(days)
    return 'schedule_not_confirmed' if days.any? { |day| !fresh?(day) || day.status.in?(%w[empty_unconfirmed unverified]) }
    return 'closed_day' if days.all? { |day| day.status == 'empty_confirmed' }

    'ok'
  end

  def slots_for(days, range)
    windows = days.flat_map { |day| windows_for_day(day) }
    slots = cabinets.flat_map { |code| slots_for_cabinet(code, windows, range) }
    slots.sort_by! { |slot| [slot[:starts_at], slot[:cabinet_code]] }
    slots.uniq! { |slot| [slot[:starts_at], slot[:ends_at]] } unless @cabinet_code
    slots
  end

  def live_provider_result(range)
    windows = nil
    availability = Integrations::Medelement::ResourceAvailabilityService.new(
      resource: @resource, from: range.first, to: range.last, slots: [], cabinet_code: @cabinet_code,
      candidate_slots: lambda do |provider_windows|
        windows = provider_windows
        cabinets.flat_map { |code| slots_for_cabinet(code, provider_windows, range) }
      end
    ).perform
    unless availability.status == 'fresh'
      state = availability.reason == 'provider_response_invalid' ? 'schedule_not_confirmed' : 'provider_unavailable'
      return result([], state, availability.checked_at)
    end

    slots = availability.slots.map do |slot|
      slot.merge(cabinet_code: slot[:medelement_cabinet_code])
    end
    slots.uniq! { |slot| [slot[:starts_at], slot[:ends_at]] } unless @cabinet_code
    result(slots, windows.blank? ? 'closed_day' : 'ok', availability.checked_at)
  end

  def windows_for_day(day)
    Array(day.windows).filter_map do |window|
      start_minute = Integer(window['start_minute'], exception: false)
      end_minute = Integer(window['end_minute'], exception: false)
      next unless start_minute && end_minute && end_minute > start_minute

      date = day.date
      midnight = provider_zone.local(date.year, date.month, date.day)
      [midnight + start_minute.minutes, midnight + end_minute.minutes, window['cabinet_code'].to_s.presence]
    end
  end

  def slots_for_cabinet(code, windows, range)
    matching = windows.filter_map do |start_at, end_at, window_cabinet|
      [start_at, end_at] if window_cabinet.blank? || window_cabinet == code
    end
    return [] if matching.empty?

    Scheduling::ResourceAvailabilityQueryService.new(
      resource: @resource, from: range.first, to: range.last, service: @service,
      duration_min: @duration_min, provider_working_windows: matching,
      replace_work_rules: true, uncapped: true
    ).perform.fetch(:slots).map { |slot| slot.merge(cabinet_code: code) }
  end

  def local_result
    slots = Scheduling::ResourceAvailabilityQueryService.new(
      resource: @resource, from: @from, to: @to, service: @service,
      duration_min: @duration_min, uncapped: true
    ).perform.fetch(:slots)
    Result.new(slots: slots, state: 'ok', checked_at: Time.current,
               source: 'local_rules', last_bookable_date: nil)
  end

  def result(slots, state, checked_at)
    Result.new(slots: slots, state: state, checked_at: checked_at,
               source: 'provider_schedule', last_bookable_date: nil)
  end

  def hook
    @hook ||= @resource.account.hooks.enabled.find_by(app_id: 'medelement')
  end

  def provider_zone
    @provider_zone ||= ActiveSupport::TimeZone[Integrations::Medelement::Configuration.new(hook: hook).time_zone] || Time.zone
  end

  def cabinets
    @cabinets ||= begin
      codes = Array(@resource.custom_attributes.to_h['medelement_cabinets']).filter_map do |payload|
        Integrations::Medelement::CabinetAttributes.code(payload).to_s.presence
      end.uniq.sort
      @cabinet_code ? codes.select { |code| code == @cabinet_code } : codes
    end
  end

  def schedule_days(from, to)
    first_date = from.in_time_zone(provider_zone).to_date
    last_date = (to - 1.second).in_time_zone(provider_zone).to_date
    stored = Integrations::Medelement::ScheduleDay.where(
      account_id: @resource.account_id, hook_id: hook.id, resource_id: @resource.id,
      specialist_code: @resource.custom_attributes.to_h['medelement_specialist_code'].to_s,
      date: first_date..last_date
    ).index_by(&:date)
    (first_date..last_date).map { |date| stored[date] || missing_day(date) }
  end

  def missing_day(date)
    Integrations::Medelement::ScheduleDay.new(date: date, status: 'unverified')
  end

  def fresh?(day)
    checked_at = day.source_checked_at
    return false unless checked_at

    offset = (day.date - Time.current.in_time_zone(provider_zone).to_date).to_i
    interval = if offset < 2
                 Integrations::Medelement::SchedulesSyncService::NEAR_REFRESH
               elsif offset < 14
                 Integrations::Medelement::SchedulesSyncService::FAR_REFRESH
               else
                 Integrations::Medelement::SchedulesSyncService::LONG_REFRESH
               end
    checked_at > Time.current - interval - FRESHNESS_MARGIN_MINUTES.minutes
  end
end
