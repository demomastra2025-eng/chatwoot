# frozen_string_literal: true

# The whole chain of a booking question in ONE call, for the patient agent of a reply suggestion: the services the patient names (with
# the price and the length the catalog has), the specialists who perform them, and the nearest free times of each specialist. Before
# it the agent walked the chain one tool per model step (search_scheduling_services, then search_scheduling_resources, then
# search_available_slots), and a model step costs about 2.5 seconds.
#
# It has no matching, availability or rule of its own. Every part is the answer of the tool that owns it, called as the agent would
# have called it, and this class only arranges the answers:
#   - the mentions go to search_scheduling_services in one request (the vector index, the threshold, the shaping of the candidates);
#   - a specialist (a name or a specialty) goes to search_scheduling_resources (the name and specialty matching);
#   - the free times come from search_available_slots (the stored MedElement hours or the local rules, the last booking time of the
#     clinic, the working hours, the times that have passed, the grid and the length of the visit).
# A service whose specialists are not recorded gets the answer search_available_slots gives for it (choose the specialist first).
#
# The answer stays small: at most MAX_SLOT_MENTIONS services get free times, each lists at most DOCTORS_PER_BLOCK specialists with
# DAYS_PER_DOCTOR days of at most five times, and the candidates of a mention are the three at most that the service search gives.
# The free times of a mention are those of its best candidate (the answer names its slots_service_id): another candidate is searched
# with search_available_slots and its service_id.
class Captain::Tools::Account::SearchBookingOptionsService < Captain::Tools::Account::BaseAccountTool
  include Captain::Tools::Account::SchedulingQueryValidation

  # The window searched when the call names no range.
  DEFAULT_RANGE_DAYS = 7
  # Services that get free times in one answer; the others are listed without them (slots_status not_searched).
  MAX_SLOT_MENTIONS = 3
  # Specialists listed with free times in one block of the answer, and the days listed for each of them.
  DOCTORS_PER_BLOCK = 4
  DAYS_PER_DOCTOR = 2
  # Specialists asked of the specialist search when a name or a specialty is given.
  SPECIALIST_LOOKUP_LIMIT = 6
  # slots_status of a service without free times in the answer, and why.
  NOT_SEARCHED = 'not_searched'
  SPECIALIST_REQUIRED = 'specialist_required'
  SPECIALIST_NOT_FOUND = 'specialist_not_found'
  SERVICE_RESOURCE_MISMATCH = 'service_resource_mismatch'
  # What the answer keeps of an answer of search_available_slots besides its days.
  SLOT_FIELDS = %w[duration_min total times_note availability availability_note requested_range_status requested_range_note].freeze
  QUERY_REQUIRED_MESSAGE = 'Pass services (the service mentions of the request) or doctor (a specialist name or a specialty).'
  ERROR_PREFIX = Captain::ToolResult::ERROR_PREFIX

  def self.name
    'search_booking_options'
  end

  description 'Booking search in one call: for the services of the request, the matching catalog services with price and duration, ' \
              'the specialists who perform them and their nearest free times; or the free times of a named specialist or specialty'
  param :services, type: :array,
                   desc: 'Service mentions, one string each: a name, an abbreviation or the patient\'s own words. All services of one ' \
                         'request go in this one list', required: false
  param :doctor, type: :string,
                 desc: 'Specialist name words or a specialty, in dictionary form as a staff list writes it', required: false
  param :from, type: :string, desc: 'Range start, YYYY-MM-DD or YYYY-MM-DDTHH:MM (clinic time); default now', required: false
  param :to, type: :string, desc: "Range end, same format; default #{DEFAULT_RANGE_DAYS} days after the start", required: false

  def execute(services: nil, doctor: nil, from: nil, to: nil)
    return tool_failure('Booking search is available to the patient agent only') unless agent_scope?

    doctor = doctor.to_s.squish.presence
    return query_required_failure unless doctor || mentions_given?(services)

    @range = search_range(from, to)
    @slot_fields = {}
    answer = booking_options(services, doctor)
    answer.is_a?(String) ? answer : compact_payload(answer)
  rescue StandardError => e
    Rails.logger.error("[#{self.class.name}] #{e.class}: #{e.message.to_s.truncate(300)}") unless e.is_a?(Scheduling::Error)
    scheduling_tool_failure(e)
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end

  private

  def tool_scope_name
    Captain::ToolAccess::SCOPE_AGENT
  end

  # The answer, or the failure text of the first of the tools that failed.
  def booking_options(services, doctor)
    catalog = service_search(services)
    specialists = specialist_search(doctor)
    failure = [catalog, specialists].compact.find { |raw| failed?(raw) }
    failure || arrange(parsed(catalog), parsed(specialists))
  end

  def service_search(services)
    read(Captain::Tools::Account::SearchSchedulingServicesService, queries: services) if mentions_given?(services)
  end

  def specialist_search(doctor)
    read(Captain::Tools::Account::SearchSchedulingResourcesService, query: doctor, limit: SPECIALIST_LOOKUP_LIMIT) if doctor
  end

  def parsed(raw)
    JSON.parse(raw) if raw
  end

  def mentions_given?(services)
    Array(services).any? { |mention| mention.to_s.squish.present? }
  end

  def query_required_failure
    scheduling_tool_failure(
      Scheduling::Error.new(code: 'QUERY_REQUIRED', message: QUERY_REQUIRED_MESSAGE, status: :unprocessable_content,
                            details: { reason: 'validation_error', field: 'services' }),
      retryable: true
    )
  end

  # [from, to] as clinic-time strings that search_available_slots reads (it never searches before now, whatever from says).
  def search_range(from, to)
    range_from = from.present? ? scheduling_datetime(from, field_name: 'from') : Time.current.in_time_zone(scheduling_time_zone)
    range_to = to.present? ? scheduling_datetime(to, field_name: 'to') : range_from + DEFAULT_RANGE_DAYS.days
    [range_from.iso8601, range_to.iso8601]
  end

  # The answer of a tool of this account for the patient agent, as the JSON text the agent would have read. The tool is built and
  # called as the agent adapter calls it: the patient scope, the fence, and the tool's own execute without the instrumentation of a
  # tool call of its own (this call is the one tool the agent called).
  def read(tool_class, **arguments)
    tool = tool_class.new(assistant, user: @user, conversation: @conversation)
    tool.patient_scope = patient_scope
    tool.agent_scope = true if agent_scope? && tool.respond_to?(:agent_scope=)
    tool.response_fence = response_fence
    execute_method = tool.method(:execute)
    execute_method = execute_method.super_method if execute_method.owner == Captain::Tools::Instrumentation && execute_method.super_method
    execute_method.call(**arguments)
  end

  def failed?(raw)
    Captain::ToolResult.error?(raw)
  end

  # The structured part ({ error, data: { code }, retryable }) of a failure text; {} when the failure has none.
  def failure_body(raw)
    JSON.parse(raw.to_s.delete_prefix(ERROR_PREFIX).strip)
  rescue JSON::ParserError
    {}
  end

  # catalog: the parsed answer of the service search (nil without services); specialists: that of the specialist search (nil without
  # doctor). The answer, or the failure text of a free-time search that failed for a reason the agent cannot fix by choosing a
  # specialist.
  def arrange(catalog, specialists)
    results = Array(catalog&.fetch('results', nil)).map(&:dup)
    ids = specialists ? Array(specialists['resources']).pluck('id').first(DOCTORS_PER_BLOCK) : []
    failure = add_service_slots(results, ids, specialist_named: specialists.present?)
    return failure if failure

    # A catalog miss does not make a named specialist's availability disappear. Keep it separate from any unmatched service.
    matched_service = results.any? { |result| result['status'] == Captain::Tools::Account::SearchSchedulingServicesService::FOUND }
    block = specialists_block(specialists, ids, with_slots: !matched_service)
    return block if block.is_a?(String)

    { results: results.presence, specialists: block, range: { from: @range.first, to: @range.last },
      times_note: hoist_times_note([*results, block].compact), queries_not_searched: catalog&.fetch('queries_not_searched', nil) }.compact
  end

  # The note that the listed times are a sample, said once for the whole answer instead of in every block (it is the note of
  # search_available_slots, see Captain::Tools::Agent::SlotsPayload::TIMES_NOTE).
  def hoist_times_note(blocks)
    blocks.filter_map { |item| item.delete('times_note') }.first
  end

  # The free times of the best candidate of each found mention (the first MAX_SLOT_MENTIONS). nil, or the failure text of a search.
  def add_service_slots(results, specialist_ids, specialist_named:)
    found = results.select { |result| result['status'] == Captain::Tools::Account::SearchSchedulingServicesService::FOUND }
    found.each_with_index do |result, index|
      skipped = skipped_slots_status(index, specialist_ids, specialist_named)
      next result['slots_status'] = skipped if skipped

      service_id = result['services'].first['id']
      fields = slot_fields(service_id, specialist_ids)
      return fields if fields.is_a?(String)

      result.merge!(fields.merge('slots_service_id' => service_id))
    end
    nil
  end

  # Why a found service gets no free times: the specialist the patient named was not found (the times of other specialists would be
  # offered as hers), or the answer is full.
  def skipped_slots_status(index, specialist_ids, specialist_named)
    return SPECIALIST_NOT_FOUND if specialist_named && specialist_ids.empty?

    NOT_SEARCHED if index >= MAX_SLOT_MENTIONS
  end

  # The specialists of the specialist search as the agent reads them; their free times only when no service holds them already (a
  # named specialist with services is searched once per service, with the service that sets the visit length).
  def specialists_block(specialists, ids, with_slots:)
    return unless specialists

    block = specialists.slice('total_count', 'has_more', 'search_status', 'resources', 'instruction')
    return block unless with_slots && ids.any?

    fields = slot_fields(nil, ids)
    fields.is_a?(String) ? fields : block.merge(fields)
  end

  # The free-time fields of one search (search_available_slots as the agent reads it) with the specialists cut to DOCTORS_PER_BLOCK
  # and DAYS_PER_DOCTOR days each; or the failure text. A service without a recorded specialist is not a failure: the answer says
  # what search_available_slots says about it. The same search is made once, for two mentions that found the same service.
  def slot_fields(service_id, resource_ids)
    @slot_fields[[service_id, resource_ids]] ||= read_slot_fields(service_id, resource_ids)
  end

  def read_slot_fields(service_id, resource_ids)
    raw = read(Captain::Tools::Account::SearchAvailableSlotsService,
               **{ from: @range.first, to: @range.last, resource_ids: resource_ids.presence, service_id: service_id,
                   limit: Captain::Tools::Agent::SlotsPayload::MAX_DAYS }.compact)
    return fields_of(JSON.parse(raw)) unless failed?(raw)

    recoverable_slot_failure(failure_body(raw)) || raw
  end

  def recoverable_slot_failure(body)
    case body.dig('data', 'code')
    when 'RESOURCE_REQUIRED'
      { 'slots_status' => SPECIALIST_REQUIRED, 'slots_note' => body['error'] }.compact
    when 'SERVICE_RESOURCE_MISMATCH'
      { 'slots_status' => SERVICE_RESOURCE_MISMATCH, 'slots_note' => body['error'],
        'eligible_resources' => body.dig('data', 'details', 'eligible_resources') }.compact
    end
  end

  def fields_of(answer)
    days, hidden = nearest_days(Array(answer['days']))
    fields = answer.slice(*SLOT_FIELDS).merge('days' => days)
    more_days = answer['more_days'].to_i + hidden[:days]
    fields['more_days'] = more_days if more_days.positive?
    fields['doctors_not_shown'] = hidden[:doctors] if hidden[:doctors].positive?
    fields['next_available'] = answer['next_available'] if answer['next_available'].present?
    fields.compact
  end

  # The specialist-days of the doctors with the earliest free time, DAYS_PER_DOCTOR days of each, in the order of the answer (by
  # date, then name). [days, { doctors: specialists left out, days: days of the listed specialists left out }].
  def nearest_days(days)
    by_doctor = days.group_by { |day| day['resource_id'] }
    listed = by_doctor.values.first(DOCTORS_PER_BLOCK)
    kept = listed.flat_map { |doctor_days| doctor_days.first(DAYS_PER_DOCTOR) }
    hidden = { doctors: by_doctor.size - listed.size, days: listed.sum(&:size) - kept.size }
    [days.select { |day| kept.include?(day) }, hidden]
  end
end
