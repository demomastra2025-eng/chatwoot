class Captain::Tools::Account::SearchAvailableSlotsService < Captain::Tools::Account::BaseAccountTool
  include Captain::Tools::Account::SchedulingQueryValidation
  include Captain::Tools::Account::AgentTimeRange
  NEXT_AVAILABLE_LOOKAHEAD_DAYS = 7
  CLOCK_DRIFT_WINDOW = 5.minutes
  # The note of an empty range on a day without reception: the agent says so and offers the days of next_available.
  NO_RECEPTION_NOTE = 'There is no reception on the requested day by the schedule (it is not a working day). Tell the patient ' \
                      'that there is no reception then and offer the nearest working days from next_available.'.freeze
  # A service with no recorded specialist is searched only for a specialist chosen first; the answer says how to choose one.
  RESOURCE_REQUIRED_MESSAGE = 'No specialist is recorded for this service, so searching all specialists could offer a doctor who ' \
                              'does not perform it. Choose the specialist first: call search_scheduling_resources with the ' \
                              'specialty that performs this service or the doctor name the patient gave, then call ' \
                              'search_available_slots again with resource_ids of that specialist and the same service_id.'.freeze

  def self.name
    'search_available_slots'
  end

  description 'Search free appointment slots using local rules or confirmed stored MedElement hours. Returned slots can be offered; ' \
              'creation checks availability again. Service link metadata describes recorded price links; ' \
              'total_slots counts only the returned slots. The patient agent gets a compact answer instead: specialist-days as ' \
              '{resource_id, name, date, times, more}, where limit counts the days and more_days says how many were left out'
  param :from, type: :string, desc: 'Range start datetime in ISO 8601 format', required: true
  param :to, type: :string, desc: 'Range end datetime in ISO 8601 format', required: true
  param :resource_ids, type: :array, desc: 'Optional list of scheduling resource IDs', required: false
  param :service_id, type: :number,
                     desc: 'Optional service ID that sets the duration; without resource_ids only specialists with a recorded price ' \
                           'link are searched', required: false
  param :duration_min, type: :number, desc: 'Optional appointment duration in minutes when no service is provided', required: false
  param :limit, type: :number, required: false,
                desc: 'Maximum number of slots to return; for the patient agent the maximum number of specialist-days listed ' \
                      "(default #{Captain::Tools::Agent::SlotsPayload::DEFAULT_DAYS}, max #{Captain::Tools::Agent::SlotsPayload::MAX_DAYS})"

  # Staff and Copilot get the full payload with the slots one by one, cut at limit. The patient agent gets the compact answer of
  # Captain::Tools::Agent::SlotsPayload: every free start of the range grouped by specialist and day, where limit is the number of
  # specialist-days listed and a day is never cut short.
  def execute(from:, to:, resource_ids: nil, service_id: nil, duration_min: nil, limit: nil, include_past: false) # rubocop:disable Metrics/ParameterLists
    @include_past = ActiveModel::Type::Boolean.new.cast(include_past) == true
    @filter_staff_past_slots = false
    search_params = build_search_params(from, to, resource_ids, service_id, duration_min)
    return agent_answer(search_params, limit) if agent_scope?
    return staff_passed_range_answer(search_params) if staff_range_passed?(search_params)

    payload = Scheduling::AvailableSlotSearchService.new(**search_params, limit: limit).perform
    payload = filter_past_staff_slots(payload) if @filter_staff_past_slots
    publish_service_match(payload)
    formatted_payload(prioritize_slot_keys(payload))
  rescue Scheduling::AvailableSlotSearchService::ResourceSelectionRequiredError
    resource_required_failure
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

  def build_search_params(from, to, resource_ids, service_id, duration_min)
    range_from, range_to = search_range(from, to)
    service_id = scheduling_service_id(service_id)
    scheduling_service!(service_id)
    service_id ||= inferred_agent_service_id(resource_ids) if duration_min.blank?
    { account: account, from: range_from, to: range_to, resource_ids: resource_ids, service_id: service_id, duration_min: duration_min }
  end

  def search_range(from, to)
    range_from = scheduling_datetime(from, field_name: 'from')
    range_to = scheduling_datetime(to, field_name: 'to')
    scheduling_range!(range_from, range_to, allow_equal: true)
    @requested_time_of_day = explicit_afternoon_request(from, range_from)
    return present_range(range_from, range_to) || [range_from, range_to] if agent_scope?

    clamp_staff_present_range(range_from, range_to)
  end

  def explicit_afternoon_request(raw_from, parsed_from)
    return if raw_from.to_s.strip.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    return if parsed_from.hour < 12

    now = Time.current.in_time_zone(parsed_from.time_zone)
    return if parsed_from.to_date == now.to_date && (parsed_from - now).abs <= CLOCK_DRIFT_WINDOW

    parsed_from
  end

  def clamp_staff_present_range(range_from, range_to)
    return [range_from, range_to] if @include_past

    now = Time.current.in_time_zone(range_from.time_zone)
    if exclude_past_slots? || (range_from < now && range_to > now)
      @filter_staff_past_slots = true
      range_from = [range_from, now].max if range_to > now
    end
    [range_from, range_to]
  end

  def range_passed?(search_params)
    agent_scope? && search_params[:to] <= Time.current
  end

  def staff_range_passed?(search_params)
    !@include_past && exclude_past_slots? && search_params[:to] <= Time.current
  end

  def staff_passed_range_answer(search_params)
    formatted_payload(
      total_slots: 0,
      slots: [],
      range: { from: search_params[:from].iso8601, to: search_params[:to].iso8601 },
      requested_service_id: search_params[:service_id],
      requested_range_status: RANGE_PASSED_STATUS,
      requested_range_note: range_passed_note('Pass a future range or include_past: true.')
    )
  end

  def filter_past_staff_slots(payload)
    now = Time.current
    filtered = Array(payload[:slots]).select do |slot|
      starts_at = slot[:starts_at] || slot['starts_at']
      starts_at.present? && Time.iso8601(starts_at.to_s) >= now
    rescue ArgumentError
      true
    end
    payload.merge(total_slots: filtered.size, slots: filtered)
  end

  # Retryable: the same search with resource_ids of a chosen specialist answers it.
  def resource_required_failure
    scheduling_tool_failure(Scheduling::Error.new(
                              code: 'RESOURCE_REQUIRED', status: :unprocessable_content, message: RESOURCE_REQUIRED_MESSAGE,
                              details: { reason: 'resource_required', next_tool: 'search_scheduling_resources' }
                            ), retryable: true)
  end

  def inferred_agent_service_id(resource_ids)
    return unless agent_scope?

    ids = Scheduling::AvailableSlotSearchService.normalize_resource_ids(resource_ids)
    return if ids.blank?

    service_ids = Scheduling::ServicePrice.active.where(account_id: account.id, resource_id: ids).distinct.pluck(:service_id)
    service_ids.first if service_ids.one?
  rescue StandardError
    nil
  end

  def prioritize_slot_keys(payload)
    payload.slice(:total_slots, :slots).merge(payload)
  end

  # Every free start of the range (a day is not cut at a count), grouped by specialist and day into the compact answer.
  def agent_answer(search_params, limit)
    return passed_range_answer(search_params) if range_passed?(search_params)

    payload = Scheduling::CompleteSlotSearchService.new(**search_params).perform
    publish_service_match(payload)
    answer = Captain::Tools::Agent::SlotsPayload.answer(payload, days_limit: limit)
    answer = answer.merge(empty_range_fields(payload, search_params)) if payload[:total_slots].to_i.zero?
    absences = Scheduling::TimeOffPayload.for(account: account, resource_ids: payload[:candidate_resource_ids],
                                              from: search_params[:from], to: search_params[:to])
    answer[:absences] = absences if absences.any?
    compact_payload(answer)
  end

  # A range that ended before now has nothing to offer: it is not searched, and the answer carries the nearest free days from now.
  def passed_range_answer(search_params)
    answer = { service_id: search_params[:service_id], total: 0, days: [], requested_range_status: RANGE_PASSED_STATUS,
               requested_range_note: range_passed_note('from next_available.') }
    compact_payload(answer.compact.merge(next_available_fields(search_params)))
  end

  def empty_range_fields(payload, search_params)
    no_reception_fields(payload, search_params).merge(next_available_fields(search_params))
  end

  def no_reception_fields(payload, search_params)
    return {} unless no_schedule_for_requested_range?(payload[:candidate_resource_ids], search_params[:from], search_params[:to])

    { requested_range_status: 'no_reception_scheduled', requested_range_note: NO_RECEPTION_NOTE }
  end

  # After an empty range: the nearest specialist-days with free time in the week that follows it, never before now.
  def next_available_fields(search_params)
    next_from = [search_params[:to], search_params[:from] + 1.minute, Time.current.in_time_zone(search_params[:from].time_zone)].max
    lookahead = Scheduling::CompleteSlotSearchService.new(
      **search_params, from: next_from, to: next_from + NEXT_AVAILABLE_LOOKAHEAD_DAYS.days
    ).perform
    days = Captain::Tools::Agent::SlotsPayload.next_available(Array(lookahead[:slots]), requested_from: @requested_time_of_day)
    days.present? ? { next_available: days } : {}
  rescue StandardError
    {}
  end

  def no_schedule_for_requested_range?(resource_ids, range_from, range_to)
    ids = Array(resource_ids)
    return false if ids.empty?

    end_date = [(range_to - 1.second).to_date, range_from.to_date].max
    dates = (range_from.to_date..end_date).to_a
    account.scheduling_resources.where(id: ids).none? { |resource| receives_on?(resource, dates) }
  rescue StandardError
    false
  end

  # Whether the schedule of the specialist has reception on any of the dates: the days the provider table knows (an empty
  # confirmed day is a day off), or the work rules and overrides of a specialist on local hours.
  def receives_on?(resource, dates)
    if Scheduling::ResourceHoursPolicy.new(resource: resource).provider_hours?
      days = Integrations::Medelement::ScheduleDay.where(account_id: account.id, resource_id: resource.id, date: dates).pluck(:status)
      days.empty? || days.any? { |status| status != 'empty_confirmed' }
    else
      resource.work_rules.active.exists?(weekday: dates.map(&:wday).uniq) || resource.workday_overrides.exists?(date: dates)
    end
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
