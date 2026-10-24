class Captain::Tools::Account::SearchAvailableSlotsService < Captain::Tools::Account::BaseAccountTool
  include Captain::Tools::Account::SchedulingQueryValidation
  NEXT_AVAILABLE_LOOKAHEAD_DAYS = 7
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
  def execute(from:, to:, resource_ids: nil, service_id: nil, duration_min: nil, limit: nil) # rubocop:disable Metrics/ParameterLists
    search_params = build_search_params(from, to, resource_ids, service_id, duration_min)
    return agent_answer(search_params, limit) if agent_scope?

    payload = Scheduling::AvailableSlotSearchService.new(**search_params, limit: limit).perform
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
    return [range_from, range_to] unless agent_scope?

    # The patient is never offered a time that has passed: a range that began earlier starts now.
    now = Time.current.in_time_zone(range_from.time_zone)
    return [range_from, range_to] unless range_from < now && (range_to > now || range_from.to_date == now.to_date)

    [now, [range_to, now].max]
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
    payload = Scheduling::CompleteSlotSearchService.new(**search_params).perform
    publish_service_match(payload)
    answer = Captain::Tools::Agent::SlotsPayload.answer(payload, days_limit: limit)
    answer = answer.merge(empty_range_fields(payload, search_params)) if payload[:total_slots].to_i.zero?
    compact_payload(answer)
  end

  def empty_range_fields(payload, search_params)
    no_reception_fields(payload, search_params).merge(next_available_fields(search_params))
  end

  def no_reception_fields(payload, search_params)
    return {} unless no_schedule_for_requested_range?(payload[:candidate_resource_ids], search_params[:from], search_params[:to])

    { requested_range_status: 'no_reception_scheduled', requested_range_note: NO_RECEPTION_NOTE }
  end

  # After an empty range: the nearest specialist-days with free time in the week that follows it.
  def next_available_fields(search_params)
    next_from = [search_params[:to], search_params[:from] + 1.minute].max
    lookahead = Scheduling::CompleteSlotSearchService.new(
      **search_params, from: next_from, to: next_from + NEXT_AVAILABLE_LOOKAHEAD_DAYS.days
    ).perform
    days = Captain::Tools::Agent::SlotsPayload.next_available(Array(lookahead[:slots]), requested_from: search_params[:from])
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
