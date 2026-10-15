class Captain::Tools::Account::SearchAvailableSlotsService < Captain::Tools::Account::BaseAccountTool
  include Captain::Tools::Account::SchedulingQueryValidation
  NEXT_AVAILABLE_LOOKAHEAD_DAYS = 7
  NEXT_AVAILABLE_LIMIT = 6

  def self.name
    'search_available_slots'
  end

  description 'Search free appointment slots using local rules or confirmed stored MedElement hours. Returned slots can be offered; ' \
              'creation checks availability again. Service link metadata describes recorded price links; ' \
              'total_slots counts only the returned slots'
  param :from, type: :string, desc: 'Range start datetime in ISO 8601 format', required: true
  param :to, type: :string, desc: 'Range end datetime in ISO 8601 format', required: true
  param :resource_ids, type: :array, desc: 'Optional list of scheduling resource IDs', required: false
  param :service_id, type: :number, desc: 'Optional service ID to filter price links and derive duration', required: false
  param :duration_min, type: :number, desc: 'Optional appointment duration in minutes when no service is provided', required: false
  param :limit, type: :number, desc: 'Maximum number of slots to return', required: false

  def execute(from:, to:, resource_ids: nil, service_id: nil, duration_min: nil, limit: nil)
    range_from = scheduling_datetime(from, field_name: 'from')
    range_to = scheduling_datetime(to, field_name: 'to')
    scheduling_range!(range_from, range_to, allow_equal: true)
    if agent_scope?
      now = Time.current.in_time_zone(range_from.time_zone)
      if range_from < now && (range_to > now || range_from.to_date == now.to_date)
        range_from = now
        range_to = [range_to, range_from].max
      end
    end
    service_id = scheduling_service_id(service_id)
    scheduling_service!(service_id)
    resource_ids = scoped_agent_resource_ids(resource_ids, service_id: service_id)
    service_id ||= inferred_agent_service_id(resource_ids) if duration_min.blank?
    search_params = {
      account: account,
      from: range_from,
      to: range_to,
      resource_ids: resource_ids,
      service_id: service_id,
      duration_min: duration_min
    }
    payload = Scheduling::AvailableSlotSearchService.new(**search_params, limit: limit).perform
    publish_service_match(payload)
    payload = attach_next_available_slots(payload, search_params) if agent_scope?

    formatted_payload(prioritize_slot_keys(payload))
  rescue Scheduling::AvailableSlotSearchService::MissingServiceLinkError => e
    scheduling_tool_failure(Scheduling::Error.new(
      code: 'SERVICE_NOT_AVAILABLE_FOR_RESOURCE', status: :unprocessable_content,
      message: "#{e.message}: no recorded service-price link for these resources; provider eligibility is unverified",
      details: { reason: 'service_not_linked' }
    ))
  rescue ActiveRecord::RecordNotFound => e
    scheduling_tool_failure(Scheduling::Error.new(code: 'RESOURCE_NOT_FOUND', message: e.message, status: :not_found,
                                                details: { reason: 'unknown_resource' }))
  rescue StandardError => e
    scheduling_tool_failure(e)
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end

  private

  def inferred_agent_service_id(resource_ids)
    return unless agent_scope?

    ids = Scheduling::AvailableSlotSearchService.normalize_resource_ids(resource_ids)
    return if ids.blank?

    service_ids = Scheduling::ServicePrice.active.where(account_id: account.id, resource_id: ids).distinct.pluck(:service_id)
    service_ids.first if service_ids.one?
  rescue StandardError
    nil
  end

  def scoped_agent_resource_ids(resource_ids, service_id: nil)
    return resource_ids unless agent_scope? && assistant.booking_resource_ids.present?

    allowed = assistant.booking_resource_ids
    requested = Scheduling::AvailableSlotSearchService.normalize_resource_ids(resource_ids)
    raise_resource_outside_scope! if (requested - allowed).any?
    return requested if requested.present?

    filter_allowed_by_service(allowed, service_id)
  end

  def filter_allowed_by_service(allowed, service_id)
    return allowed if service_id.blank?

    linked = Scheduling::ServicePrice.active.where(account_id: account.id, service_id: service_id).distinct.pluck(:resource_id)
    return allowed if linked.empty?

    scoped = allowed & linked
    return scoped if scoped.present?

    raise_resource_outside_scope!
  end

  def raise_resource_outside_scope!
    raise Scheduling::Error.new(
      code: 'RESOURCE_UNAVAILABLE', message: 'Resource is outside this agent booking scope',
      status: :not_found, details: { reason: 'resource_outside_scope' }
    )
  end

  def prioritize_slot_keys(payload)
    payload.slice(:total_slots, :slots, :requested_range_status, :requested_range_note, :next_available_slots).merge(payload)
  end

  def attach_next_available_slots(payload, search_params)
    return payload unless payload[:total_slots].to_i.zero?

    if no_schedule_for_requested_range?(payload[:candidate_resource_ids], search_params[:from], search_params[:to])
      payload = payload.merge(
        requested_range_status: 'no_reception_scheduled',
        requested_range_note: 'В запрошенный день приёма по расписанию нет (не приёмный день); сообщите, что приёма по расписанию нет, и предложите ближайшие дни приёма из next_available_slots.'
      )
    end
    next_from = [search_params[:to], search_params[:from] + 1.minute].max
    lookahead = Scheduling::AvailableSlotSearchService.new(
      **search_params,
      from: next_from,
      to: next_from + NEXT_AVAILABLE_LOOKAHEAD_DAYS.days,
      limit: Scheduling::AvailableSlotSearchService::MAX_LIMIT
    ).perform
    next_slots = select_next_available_slots(Array(lookahead[:slots]), search_params[:from])
    next_slots.present? ? payload.merge(next_available_slots: next_slots) : payload
  rescue StandardError
    payload
  end

  def no_schedule_for_requested_range?(resource_ids, range_from, range_to)
    ids = Array(resource_ids)
    return false if ids.empty?

    resources = account.scheduling_resources.where(id: ids)
    end_date = [(range_to - 1.second).to_date, range_from.to_date].max
    dates = (range_from.to_date..end_date).to_a
    weekdays = dates.map(&:wday).uniq
    resources.none? do |res|
      res.work_rules.active.exists?(weekday: weekdays) || res.workday_overrides.exists?(date: dates)
    end
  rescue StandardError
    false
  end

  def select_next_available_slots(slots, requested_from)
    return [] if slots.empty?

    candidates = slots
    if requested_from.present? && requested_from.hour >= 12
      min_minute = (requested_from.hour * 60) + requested_from.min
      afternoon = slots.select do |slot|
        starts_at = Time.zone.parse(slot[:starts_at].to_s)
        ((starts_at.hour * 60) + starts_at.min) >= min_minute
      end
      candidates = afternoon if afternoon.present?
    end
    half_hour = candidates.select { |slot| (Time.zone.parse(slot[:starts_at].to_s).min % 30).zero? }
    (half_hour.size >= 3 ? half_hour : candidates).first(NEXT_AVAILABLE_LIMIT)
  end

  def publish_service_match(payload)
    match = payload.fetch(:service_match)
    event_name = match.fetch(:confirmed) ? 'captain.service_match_confirmed' : 'captain.service_match_missing'
    Llm::EventBus.publish(
      event_name,
      feature: 'assistant',
      runtime_mode: 'captain_runtime',
      account_id: account.id,
      conversation_id: current_conversation&.id,
      service_id: payload[:requested_service_id],
      resource_ids: match[:resource_ids]
    )
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][Scheduling] Failed to publish service match: #{e.class}: #{e.message}")
  end
end
