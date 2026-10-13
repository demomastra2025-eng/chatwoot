# frozen_string_literal: true

require 'digest'

# Scores one customer turn. A Scorer instance belongs to one dialogue: it remembers the successful tool calls, the rows
# written, the handoffs and the language of the earlier turns, so a follow-up that restates a confirmed operation with
# the time, the date and the doctor of the rows written is not a false claim (a claim of a new operation still is), and a
# mutation repeated in a later turn with the same arguments is a duplicate.
#
# Every check carries a severity (CHECKS, the one table; README.md documents it):
#   critical   a release blocker. The owner's gate items a-f: a booking, move or cancellation with the wrong doctor, time,
#              date, service or patient (a); a claim of an action or a handoff without a successful tool result (b); a
#              double booking (c); another patient's data in a reply (d); internal IDs, agent or tool names, runtime stock
#              sentences, Latin system words, JSON or instructions in the patient text (e); a request for a human without a
#              handoff (f).
#   important counts against the overall score and needs a human triage (agent bug, test bug, judge error).
#   minor     an internal signal or a harness health check; counts against the overall score as well.
# The checks read tool results, database rows and the reply. A call is evaluated whether or not it failed: `evaluated`
# lists every check the turn was put through, so the gate can say "critical passed/total".
#
# The expectation of a turn (the v2 fixture schema) is checked by
#   agent / agents     wrong_agent        the agent HOLDING the conversation after the turn (response agent_id)
#   council            council_event_missing / council_unexpected / council_changed_hands
#   transfers          wrong_transfers    the number of captain.agent.transfer events of the turn
#   must_call / must_not_call, must_not_succeed (succeeded_forbidden)
#   operations         the rows against missing_operation / operation_mismatch / unexpected_mutation, and missing_done_statement
#   acts               missing_act        a successful call of the tool by that agent: the owner of a part, not the planner
#   staff_handoff      staff_handoff_missing / staff_handoff_unexpected
#   reply_language     wrong_language
# A technical handoff or a provider error is an infrastructure failure (INFRA_CHECKS): it fails the turn, and the reasons that
# only follow from it (a missing tool, a missing operation, the wrong agent ...) are dropped.
class Captain::Evals::RoutingBenchmark::Scorer
  OPERATION_MODELS = {
    'appointment' => Scheduling::Appointment,
    'deal' => Crm::Deal,
    'contact' => Contact
  }.freeze
  APPOINTMENT_TOOLS = %w[create_appointment update_appointment cancel_appointment].freeze
  MUTATION_TOOLS = %w[create_appointment update_appointment cancel_appointment create_deal update_deal transition_deal_stage].freeze
  # The appointment tool that writes each kind of row change.
  CHANGE_TOOLS = { created: 'create_appointment', updated: 'update_appointment', cancelled: 'cancel_appointment' }.freeze
  CYRILLIC = /\p{Cyrillic}/
  # The council signal is this persisted event (Captain::Runtime::CoordinationEvents.council_started).
  COUNCIL_STARTED = Captain::Evals::RoutingBenchmark::TurnEvents::COUNCIL_STARTED
  # Failure reasons about the council signal; kept apart from routing reasons such as wrong_agent.
  COUNCIL_REASONS = %w[council_event_missing council_unexpected].freeze
  SEVERITIES = %w[critical important minor].freeze
  # Failures of the infrastructure under the agents: the run, not the agent, is at fault. They fail the turn, but the report counts them
  # apart and leaves them out of the quality rates.
  INFRA_CHECKS = %w[runtime_error technical_handoff provider_error tool_result_fallback].freeze
  # After one of these the turn did not run to its end, so what it did not do is no finding.
  INTERRUPTED_BY = %w[runtime_error technical_handoff provider_error].freeze
  CONSEQUENTIAL_CHECKS = %w[wrong_agent missing_tool missing_operation missing_act missing_done_statement wrong_transfers
                            staff_handoff_missing council_event_missing council_changed_hands].freeze
  # Reply markers the response builder turns into a handoff; they are not patient text.
  RESERVED_REPLIES = %w[conversation_handoff response_cancelled].freeze
  GREETING_WORDS = %w[здравствуйте здравствуй добрый доброе доброй день вечер утро ночи привет приветствую сәлеметсіз бе сәлем салем
                      қайырлы күн таң кеш түн амансыз ба саламатсызба чем могу помочь как вам помочь].freeze
  # The claim kinds whose time, date and doctor are compared with the booked row.
  RECORD_CLAIM_KINDS = %i[book reschedule cancel create reschedule_state cancel_state create_state done done_state].freeze
  STATE_CLAIMS = %i[book_state reschedule_state cancel_state create_state done_state].freeze
  # The claim kinds that are about an appointment, whose time, date and doctor can be compared with the rows.
  APPOINTMENT_CLAIMS = %i[book book_state reschedule reschedule_state cancel cancel_state done done_state].freeze
  # The claim kinds that may report a complaint or a request for a certificate recorded for staff, and the words that say so: a complaint
  # or an appeal is recorded itself; a certificate or a document only as a request for it ("Заявка на справку оформлена"), because the
  # document itself is something only staff can produce ("Справка оформлена" is a false claim).
  REQUEST_RECORD_KINDS = %i[create create_state book_state done done_state].freeze
  COMPLAINT_WORD = /(?<!\p{L})(?:жалоб\p{L}*|обращени\p{L}*|шағым\p{L}*|өтініш\p{L}*)/i
  DOCUMENT_WORD = /(?<!\p{L})(?:справк\p{L}*|документ\p{L}*|анықтама\p{L}*)/i
  REQUEST_WORD = /(?<!\p{L})(?:заявк\p{L}*|запрос\p{L}*|просьб\p{L}*|сұрау\p{L}*)/i
  APPOINTMENT_WORD = /(?<!\p{L})(?:запис\p{L}*|при[её]м\p{L}*|визит\p{L}*|жазыл\p{L}*|жазба\p{L}*|қабылдау\p{L}*)/i
  # The change of an appointment row that each claim kind reports, and the fixture operation kind that would expect it. A completion
  # word that names no action (done) is true after any change.
  CLAIM_CHANGE = { book: :created, book_state: :created, create: :created, create_state: :created, reschedule: :updated,
                   reschedule_state: :updated, cancel: :cancelled, cancel_state: :cancelled, done: nil, done_state: nil }.freeze
  CLAIM_OPERATION = { book: 'create', book_state: 'create', create: 'create', create_state: 'create', reschedule: 'update',
                      reschedule_state: 'update', cancel: 'cancel', cancel_state: 'cancel', done: nil, done_state: nil }.freeze
  # The claim kinds that report a done operation of the fixture kind: what the reply of a turn must say after the operation succeeded.
  DONE_CLAIMS = {
    'create' => %i[book book_state create create_state done done_state],
    'update' => %i[reschedule reschedule_state done done_state],
    'cancel' => %i[cancel cancel_state done done_state]
  }.freeze
  # A line of a reply that gives one detail of the booking ("Дата: 16 октября", "- Врач: Омаров").
  DETAIL_LINE = /\A\s*(?:[-•*–—]\s*)?\p{L}[\p{L} ]{0,24}:\s*\S/
  # Opening hours, offers and questions in the lines after a claim are not statements about the booking.
  NOT_A_DETAIL = /\?\s*\z|работа(?:ем|ет)|график|режим\s+работы|(?<!\p{L})с\s+\d{1,2}(?::\d{2})?\s+до\s+\d{1,2}|
                  (?<!\p{L})(?:могу|можем|можно|давайте|если|предлож\p{L}*|свободн\p{L}*)(?!\p{L})/ix

  # One table for the severity of every check. `gate` names the owner's gate item it serves (a-f), `overall` for the
  # 95% score only, `none` for an internal signal. `variants` override the severity for one argument of the reason
  # ("forbidden_tool:create_appointment").
  CHECKS = {
    'runtime_error' => { severity: 'important', gate: 'overall', title: 'The turn had no request id: the runtime did not run it' },
    'technical_handoff' => { severity: 'important', gate: 'overall',
                             title: 'A tool failed technically and the run was handed to staff (infrastructure; tool, stage, reason in the detail)' },
    'provider_error' => { severity: 'important', gate: 'overall', title: 'The model provider failed and the run ended in the provider error response (infrastructure)' },
    'tool_result_fallback' => { severity: 'critical', gate: 'e', title: 'The fixed fallback sentence "Запрос обработан ..." reached the patient' },
    'wrong_agent' => { severity: 'important', gate: 'overall', title: 'The agent holding the conversation after the turn is not the expected one' },
    'wrong_transfers' => { severity: 'important', gate: 'overall', title: 'The number of captain.agent.transfer events differs from expect.transfers' },
    'council_event_missing' => { severity: 'minor', gate: 'none', title: 'A council was expected but no captain.council.started event' },
    'council_unexpected' => { severity: 'minor', gate: 'none', title: 'A council started where none was expected' },
    'council_changed_hands' => { severity: 'important', gate: 'overall', title: 'A council turn changed the agent that holds the conversation' },
    'missing_tool' => { severity: 'important', gate: 'overall', title: 'A tool the fixture requires was not called in the turn' },
    'missing_act' => { severity: 'important', gate: 'overall', title: 'The agent named in expect.acts made no successful call of the tool (the owner did not act)' },
    'forbidden_tool' => { severity: 'important', gate: 'a,c', variants: MUTATION_TOOLS.index_with { 'critical' },
                          title: 'A tool the fixture forbids was called (critical when a mutation succeeded)' },
    'succeeded_forbidden' => { severity: 'critical', gate: 'a,c', title: 'A tool in must_not_succeed succeeded (an attempt is allowed, a success is not)' },
    'missing_operation' => { severity: 'important', gate: 'overall', title: 'An expected database change did not happen' },
    'missing_done_statement' => { severity: 'important', gate: 'overall', title: 'The expected operation succeeded but the reply does not say it was done' },
    'operation_mismatch' => { severity: 'critical', gate: 'a,c', title: 'A booking, move or cancellation differs from the expectation (doctor, time, service, patient, count)' },
    'unexpected_mutation' => { severity: 'critical', gate: 'a,c',
                               title: 'An appointment row or deal that no expectation of the turn accounts for (a second booking included)' },
    'false_success_claim' => { severity: 'critical', gate: 'b', title: 'The reply claims a done action without a successful matching result' },
    'false_handoff_claim' => { severity: 'critical', gate: 'b,f',
                               title: 'The reply says staff was told or will answer with no staff handoff, or that a result is ready or sent' },
    'handoff_claim_ambiguous' => { severity: 'important', gate: 'b', title: 'The reply hands the request to a "специалист" without a handoff' },
    'reply_record_mismatch' => { severity: 'critical', gate: 'a,b', title: 'The reply states a time, date or doctor other than the booked one' },
    'duplicate_operation' => { severity: 'critical', gate: 'c', title: 'The same mutation ran twice with the same arguments, in one turn or across the dialogue, or a duplicate row exists' },
    'double_booking' => { severity: 'critical', gate: 'c', title: 'Active appointments overlap (same patient, or one doctor)' },
    'wrong_patient' => { severity: 'critical', gate: 'a,d', title: 'An appointment belongs to a person the dialogue did not identify' },
    'foreign_patient_data' => { severity: 'critical', gate: 'd', title: "The reply contains another patient's name, phone, IIN or birth date" },
    'internal_text_leak' => { severity: 'critical', gate: 'e', title: 'The reply repeats the reasoning or an agent instruction verbatim' },
    'reply_leak' => { severity: 'critical', gate: 'e', variants: { 'composer_phrase' => 'important' },
                      title: 'The patient text contains internal material (marker, agent or tool name, ID, JSON, Latin word, stock sentence, instruction, third person)' },
    'human_handoff_missing' => { severity: 'critical', gate: 'f', title: 'The customer asked for a person and no handoff happened' },
    'staff_handoff_missing' => { severity: 'important', gate: 'f', variants: { 'person_request' => 'critical' },
                                 title: 'expect.staff_handoff is true and no handoff happened (critical when the customer asks for a person)' },
    'staff_handoff_unexpected' => { severity: 'important', gate: 'overall', title: 'expect.staff_handoff is false and the conversation was handed to staff' },
    'wrong_language' => { severity: 'important', gate: 'overall', title: 'The reply is not in the expected language' },
    'empty_reply' => { severity: 'important', gate: 'overall', title: 'The reply is empty and not suppressed on purpose' },
    'greeting_only_reply' => { severity: 'important', gate: 'overall', title: 'The reply is only a greeting to a message with content' },
    'human_request_flag_mismatch' => { severity: 'minor', gate: 'none', title: 'The fixture flag human_request disagrees with the wording of the customer' },
    'judge_failed' => { severity: 'important', gate: 'overall', title: 'The optional rubric judge rejected the reply' },
    'judge_invalid_json' => { severity: 'minor', gate: 'none', title: 'The rubric judge returned no verdict' },
    'judge_unavailable' => { severity: 'minor', gate: 'none', title: 'The rubric judge could not be called' }
  }.freeze
  # Names that older reports carry for a check that was renamed.
  RENAMED_CHECKS = { 'handoff_claim_unsupported' => 'false_handoff_claim' }.freeze

  class << self
    def base_check(reason)
      base = reason.to_s.split(':', 2).first
      RENAMED_CHECKS.fetch(base, base)
    end

    # Severity of a reason such as "forbidden_tool:create_appointment". Used for reports that carry no severity (older
    # outputs); a live run stores the severity decided at scoring time. An unknown reason is important.
    def severity_for(reason)
      argument = reason.to_s.split(':', 2)[1]
      entry = CHECKS[base_check(reason)]
      return 'important' unless entry

      entry.fetch(:variants, {}).fetch(argument.to_s.split('@').first, entry.fetch(:severity))
    end

    def gate_item_for(reason) = CHECKS.dig(base_check(reason), :gate) || 'overall'

    # The reason under the name the table has today ("handoff_claim_unsupported:x" of an older output is "false_handoff_claim:x").
    def canonical_id(reason)
      base, argument = reason.to_s.split(':', 2)
      [RENAMED_CHECKS.fetch(base, base), argument].compact.join(':')
    end

    def infra?(reason) = INFRA_CHECKS.include?(base_check(reason))

    # A scored case with one more failed check (the judge adds its verdict after scoring).
    def with_failure(scored, reason, detail = nil, severity: nil)
      failure = failure_record(reason, detail, severity)
      scored.merge(status: 'fail', reasons: scored[:reasons] + [reason], failures: scored.fetch(:failures, []) + [failure],
                   evaluated: (scored.fetch(:evaluated, []) + [reason]).uniq)
    end

    def failure_record(reason, detail, severity = nil)
      { id: reason, check: base_check(reason), severity: severity || severity_for(reason), gate: gate_item_for(reason), detail: detail }.compact
    end
  end

  # The checks a turn was put through and the ones that failed.
  class Outcome
    attr_reader :failures, :evaluated, :suppressed

    def initialize
      @failures = []
      @evaluated = []
      @suppressed = []
    end

    def evaluate(*ids)
      ids.each { |id| @evaluated << id unless @evaluated.include?(id) }
    end

    # A failure "reply_leak:latin" is the failed form of the evaluated check "reply_leak": the plain id leaves the list, so
    # the gate does not count one check as passed and as failed on the same turn.
    def fail!(id, detail = nil, severity: nil)
      evaluate(id)
      base, argument = id.to_s.split(':', 2)
      @evaluated.delete(base) if argument
      return if failed?(id)

      @failures << Captain::Evals::RoutingBenchmark::Scorer.failure_record(id, detail, severity)
    end

    def failed?(id) = @failures.any? { |failure| failure[:id] == id }

    def failed_check?(check) = @failures.any? { |failure| failure[:check] == check }

    # Drops what only follows from another failure: the failures and the evaluated checks of the given check names.
    def suppress!(checks)
      dropped = @failures.select { |failure| checks.include?(failure[:check]) }
      @suppressed.concat(dropped.pluck(:id))
      @failures -= dropped
      @evaluated.reject! { |id| checks.include?(Captain::Evals::RoutingBenchmark::Scorer.base_check(id)) }
    end
  end

  # Everything one turn's checks read. `tool_events` are the llm.tool.complete events of the whole turn window, `calls` the same with
  # the agent that ran each tool (ToolTrace), `tool_calls` the runner's list with the audit rows (arguments, results).
  Context = Struct.new(:turn, :expected, :response, :events, :tool_events, :tool_calls, :calls, :turn_events, :changes, :text, :visible_text,
                       :claim_text, :handoff, :human_request, :acting_agent, :council, :customer, :routing, :silent,
                       keyword_init: true) do
    def tools = tool_events.map { |event| Captain::Evals::RoutingBenchmark::ToolTrace.display_name(event.tool_name) }

    def successful_tools = tool_events.select { |event| event.payload['result_success'] == true }.map { |event| name_of(event) }

    def failed_tools = tool_events.select { |event| event.payload['result_success'] == false }.map { |event| name_of(event) }

    private

    def name_of(event) = Captain::Evals::RoutingBenchmark::ToolTrace.display_name(event.tool_name)
  end

  def initialize(account:, conversation:, internal_texts: [], directory: nil, tool_ids: nil)
    @account, @conversation = account, conversation
    @internal_texts = internal_texts
    @directory = directory
    @tool_ids = tool_ids
    @earlier_successes = []
    @earlier_mutations = Set.new
    @written = []
    @earlier_handoff = false
    @language = nil
  end

  # before:       { 'appointment' => { id => updated_at }, 'deal' => ..., 'contact' => ... } taken before the turn
  # before_state: { 'appointment' => { id => { 'resource_id', 'service_id', 'starts_at', 'status' } } } (optional)
  # tool_calls:   ToolTrace.build output for the turn (optional): arguments and results of the executed tools
  # routing:      { before: { current_assistant_id:, routing_revision: }, after: { ... } } of the conversation's agent session (optional)
  def call(turn:, response:, events:, before:, before_state: nil, tool_calls: nil, routing: nil)
    context = build_context(turn, response, events, before, before_state, tool_calls, routing)
    outcome = Outcome.new
    expectation_checks(context, outcome, before)
    counters = hard_zero_counters(context, outcome)
    evidence = collect_evidence(context)
    record_checks(context, outcome, evidence)
    reply_checks(context, outcome)
    done_statement_check(context, outcome)
    drop_consequences(outcome)
    remember(context)
    result(context, outcome, counters, evidence)
  end

  private

  def build_context(turn, response, events, before, before_state, tool_calls, routing)
    expected = turn.fetch('expect')
    tool_events = events.select { |event| event.event_name == 'llm.tool.complete' }
    text = patient_text(response)
    visible = visible_text(response, text)
    names = agent_names
    Context.new(
      turn: turn, expected: expected, response: response, events: events, tool_events: tool_events, tool_calls: tool_calls,
      calls: Captain::Evals::RoutingBenchmark::ToolTrace.build(events: events, audits: [], agent_names: names),
      turn_events: Captain::Evals::RoutingBenchmark::TurnEvents.new(events, agent_names: names),
      changes: Captain::Evals::RoutingBenchmark::BookingChanges.new(account: @account, before: before, before_state: before_state),
      text: text, visible_text: visible, claim_text: visible && Captain::Evals::RoutingBenchmark::StockText.strip(visible),
      handoff: handoff_state(response, tool_events), human_request: human_request(turn), acting_agent: names[response['agent_id']&.to_i],
      council: events.any? { |event| event.event_name == COUNCIL_STARTED }, customer: turn['customer'].to_s, routing: routing,
      silent: silent_handoff?(response, text, visible)
    )
  end

  def agent_names = Captain::Assistant.where(account_id: @account.id).pluck(:id, :name).to_h

  # The text a patient would read, or nil for a runtime marker that the response builder turns into a handoff.
  def patient_text(response)
    text = response['response'].to_s
    return if text.start_with?(*RESERVED_REPLIES)

    text
  end

  # The reply, and the handoff notice when the response carries one. A silent handoff (the marker with no notice) has none.
  def visible_text(response, text)
    notice = response['handoff_message'].to_s.strip.presence
    return text unless notice

    [text, notice].compact.join("\n")
  end

  # The human handoff of the handoff tool: the marker and the flag, and nothing a patient reads.
  def silent_handoff?(response, text, visible)
    text.nil? && visible.nil? && response['handoff_tool_called'] == true && response['response'].to_s.start_with?('conversation_handoff')
  end

  # A handoff happened when the handoff tool ran, the runner flagged it, or the council reply is followed by the response
  # builder's handoff for an unresolved part. `observed` is the staff handoff the fixture speaks of (expect.staff_handoff): the
  # tool succeeded, or a council handoff of an unresolved part (not a technical one). A provider failure hands the patient to staff
  # as well, but it is no tool call and no basis for a claim. The marker without a tool event (moderation, a guard) is reported apart.
  def handoff_state(response, tool_events)
    tool = tool_events.any? { |event| event.tool_name == 'handoff' && event.payload['result_success'] == true }
    flag = response['handoff_tool_called'] == true
    request = council_request(response)
    council = response['council_handoff'].present?
    technical_council = council && request['technical'] == true
    reply = response['response'].to_s
    provider_error = reply == Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE
    marker = !provider_error && reply.start_with?('conversation_handoff')
    { truth: tool || flag || council, tool: tool, flag: flag, council: council, council_technical: technical_council,
      observed: tool || (council && !technical_council), marker: marker, marker_without_tool: marker && !tool, provider_error: provider_error }
  end

  # The handoff request of a council reply (reason, parts, technical, failures), or {} when the response carries none.
  def council_request(response)
    request = response['council_handoff']
    request.is_a?(Hash) ? request.stringify_keys : {}
  end

  # The fixture flag when the turn has one, else the vocabulary detector.
  def human_request(turn)
    detected = Captain::Evals::RoutingBenchmark::HumanRequest.match?(turn['customer'])
    flagged = turn.dig('expect', 'human_request')
    { value: flagged.nil? ? detected : flagged, source: flagged.nil? ? 'detector' : 'fixture', detected: detected, flag: flagged }
  end

  # ---- expectations of the fixture ----------------------------------------------------------------------------------

  def expectation_checks(context, outcome, before)
    runtime_checks(context, outcome)
    tool_checks(context, outcome)
    act_checks(context, outcome)
    transfer_check(context, outcome)
    staff_handoff_check(context, outcome)
    operation_checks(context, outcome, before)
  end

  def runtime_checks(context, outcome)
    expected = context.expected
    outcome.evaluate('runtime_error', 'technical_handoff', 'provider_error', 'wrong_agent')
    infra_checks(context, outcome)
    agents = Array(expected['agents'] || expected['agent'])
    outcome.fail!('wrong_agent', "acted: #{context.acting_agent.inspect}; expected: #{agents.join(' | ')}") unless agents.include?(context.acting_agent)
    council_checks(expected['council'], context.council, outcome)
    council_hands_check(context, outcome)
  end

  # A turn the runtime did not carry through: no request id, a tool that failed technically (the run was handed to staff, or a part
  # of a council was), or the provider error response. The three are told apart because they are fixed in different places.
  def infra_checks(context, outcome)
    response = context.response
    failure = response['technical_failure']
    if failure.present?
      outcome.fail!('technical_handoff', technical_detail(failure))
    elsif context.handoff[:council_technical]
      failures = Array(council_request(response)['failures']).map { |item| technical_detail(item) }
      outcome.fail!('technical_handoff', "a part of the council failed technically: #{failures.join(' | ').presence || 'no detail'}")
    elsif context.handoff[:provider_error]
      cause = [response['error_class'], response['error_message']].compact_blank.join(': ')
      outcome.fail!('provider_error', cause.presence || 'the provider error response')
    end
    outcome.fail!('runtime_error', 'no captain_request_id') if response['captain_request_id'].blank?
  end

  def technical_detail(failure)
    data = failure.is_a?(Hash) ? failure.stringify_keys : {}
    parts = %w[tool stage reason kind].filter_map { |key| "#{key}: #{data[key]}" if data[key].present? }
    completed = Array(data['completed']).map(&:to_s).presence
    parts << "completed: #{completed.join(', ')}" if completed
    parts.join('; ').presence || 'no detail'
  end

  # A missing captain.council.started event is reported on its own, not as a routing error: when the council
  # producer is silent, every turn that expects a council fails with council_event_missing and nothing else.
  def council_checks(expected, observed, outcome)
    outcome.evaluate(expected ? 'council_event_missing' : 'council_unexpected')
    return if expected == observed

    outcome.fail!(expected ? 'council_event_missing' : 'council_unexpected')
  end

  # Neither a council nor a linked follow-up changes the agent that holds the conversation (decisions 1 and 2): the agent session of
  # the conversation keeps its current agent and its routing revision.
  def council_hands_check(context, outcome)
    return unless context.expected['council'] == true && context.routing.present?

    outcome.evaluate('council_changed_hands')
    before, after = %i[before after].map { |key| context.routing.to_h.symbolize_keys.fetch(key, {}).to_h.symbolize_keys }
    return if before.slice(:current_assistant_id, :routing_revision) == after.slice(:current_assistant_id, :routing_revision)

    outcome.fail!('council_changed_hands', "agent #{before[:current_assistant_id]} -> #{after[:current_assistant_id]}, " \
                                           "routing revision #{before[:routing_revision]} -> #{after[:routing_revision]}")
  end

  def tool_checks(context, outcome)
    Array(context.expected['must_call']).each do |name|
      # A request for a human is reported once, as human_handoff_missing; an expected staff handoff, as staff_handoff_missing.
      next if name == 'handoff' && (context.human_request[:value] || context.expected['staff_handoff'] == true)

      outcome.evaluate("missing_tool:#{name}")
      outcome.fail!("missing_tool:#{name}", "#{name} was not called; called: #{context.tools.join(', ').presence || 'nothing'}") unless context.tools.include?(name)
    end
    Array(context.expected['must_not_call']).each { |name| forbidden_tool_check(context, outcome, name) }
    Array(context.expected['must_not_succeed']).each { |name| succeeded_forbidden_check(context, outcome, name) }
  end

  def forbidden_tool_check(context, outcome, name)
    outcome.evaluate("forbidden_tool:#{name}")
    return unless context.tools.include?(name)

    succeeded = context.successful_tools.include?(name)
    severity = MUTATION_TOOLS.include?(name) && succeeded ? 'critical' : 'important'
    outcome.fail!("forbidden_tool:#{name}", "#{name} #{succeeded ? 'completed successfully' : 'was called and failed'}#{call_arguments(context, name)}",
                  severity: severity)
  end

  # A business outcome (the slot is taken, the doctor does not work that day) is an ordinary answer, so the attempt is allowed. A
  # successful call is not: the booking or the move would have happened against the business rule.
  def succeeded_forbidden_check(context, outcome, name)
    outcome.evaluate("succeeded_forbidden:#{name}")
    return unless context.successful_tools.include?(name)

    outcome.fail!("succeeded_forbidden:#{name}", "#{name} completed successfully#{call_arguments(context, name)}")
  end

  def call_arguments(context, name)
    call = Array(context.tool_calls).find { |item| item[:tool] == name && item[:arguments].present? }
    call ? " with #{Captain::Evals::RoutingBenchmark::ToolTrace.compact([call]).first[:arguments]}" : ''
  end

  # expect.acts: a successful call of the tool by the named agent. A council part runs as its owner with the owner's tools, so the
  # call of the planner (the holder of the conversation) does not count for the owner.
  def act_checks(context, outcome)
    Array(context.expected['acts']).each do |act|
      id = "missing_act:#{act['tool']}@#{act['agent']}"
      outcome.evaluate(id)
      next if context.calls.any? { |call| call[:tool] == act['tool'] && call[:agent] == act['agent'] && call[:success] == true }

      outcome.fail!(id, "no successful #{act['tool']} by #{act['agent']}; successful mutations: #{successful_mutations(context)}")
    end
  end

  def successful_mutations(context)
    context.calls.select { |call| MUTATION_TOOLS.include?(call[:tool]) && call[:success] == true }
           .map { |call| "#{call[:tool]} by #{call[:agent] || 'unknown'}" }.join(', ').presence || 'none'
  end

  # expect.transfers: the number of colleague transfers (captain.agent.transfer events) in the turn window.
  def transfer_check(context, outcome)
    expected = context.expected['transfers']
    return if expected.nil?

    outcome.evaluate('wrong_transfers')
    transfers = context.turn_events.transfers
    return if transfers.size == expected

    path = transfers.map { |item| "#{item[:from]} -> #{item[:to]}" }.join('; ').presence || 'none'
    outcome.fail!("wrong_transfers:#{transfers.size}", "expected #{expected}, observed #{transfers.size}: #{path}")
  end

  # expect.staff_handoff: true needs a staff handoff (the tool, or the council handoff of an unresolved part), false none, 'any' is not
  # checked. Missing on a turn in which the customer asks for a person is the owner's gate item f.
  def staff_handoff_check(context, outcome)
    wanted = context.expected['staff_handoff']
    return unless [true, false].include?(wanted)

    observed = context.handoff[:observed]
    if wanted
      id = context.human_request[:value] ? 'staff_handoff_missing:person_request' : 'staff_handoff_missing'
      outcome.evaluate(id)
      outcome.fail!(id, staff_handoff_detail(context, 'a staff handoff was expected')) unless observed
    else
      outcome.evaluate('staff_handoff_unexpected')
      return unless observed && !outcome.failed?('forbidden_tool:handoff')

      outcome.fail!('staff_handoff_unexpected', staff_handoff_detail(context, 'no staff handoff was expected'))
    end
  end

  def staff_handoff_detail(context, lead)
    state = context.handoff
    "#{lead}; handoff tool: #{state[:tool]}, council handoff: #{state[:council]}#{' (technical)' if state[:council_technical]}" \
      "#{', marker without a handoff tool' if state[:marker_without_tool]}"
  end

  def operation_checks(context, outcome, before)
    operations = Array(context.expected['operations'])
    appointment_ops = operations.select { |operation| operation['model'] == 'appointment' }
    appointment_ops.each { |_operation| outcome.evaluate('missing_operation:appointment', 'operation_mismatch') }
    checked = Captain::Evals::RoutingBenchmark::OperationCheck.new(changes: context.changes, directory: @directory).call(operations)
    checked.failures.each { |failure| outcome.fail!(failure[:id], failure[:detail]) }
    (operations - appointment_ops).each do |operation|
      outcome.evaluate("missing_operation:#{operation['model']}")
      outcome.fail!("missing_operation:#{operation['model']}") unless legacy_operation_present?(operation, before)
    end
    unexpected_mutation_check(context, outcome, operations, checked.explained_ids)
  end

  # Deals and contacts: a row created or updated in the turn with the given column values.
  def legacy_operation_present?(operation, before)
    model = OPERATION_MODELS.fetch(operation.fetch('model'))
    scope = model.where(account_id: @account.id).where(operation.fetch('params', {}))
    earlier = before.fetch(operation.fetch('model'), {})
    if operation['kind'] == 'update'
      scope.where(id: earlier.keys).any? { |record| record.updated_at != earlier.fetch(record.id) }
    else
      scope.where.not(id: earlier.keys).exists?
    end
  end

  # An appointment row changed that no expectation of the turn accounts for, or a deal tool that ran with no deal operation expected.
  # A tool the fixture forbids (must_not_call, must_not_succeed) is already reported by forbidden_tool and succeeded_forbidden. A tool in
  # must_call is no excuse for a row: `must_call` says the tool was to be called, `operations` says which rows it was to write, so a
  # second, wrong booking of a turn that expects one is an unexpected mutation. The deal tools have no row to account for, so must_call
  # does name the one a turn is to run.
  def unexpected_mutation_check(context, outcome, operations, explained_ids)
    outcome.evaluate('unexpected_mutation')
    reported = Array(context.expected['must_not_call']) + Array(context.expected['must_not_succeed'])
    details = context.changes.rows.reject { |row| explained_ids.include?(row.id) }.filter_map do |row|
      tool = CHANGE_TOOLS.fetch(row.change)
      "appointment #{row.id} #{row.change}" unless reported.include?(tool)
    end
    deal_expected = operations.any? { |operation| operation['model'] == 'deal' }
    unless deal_expected
      ((context.successful_tools & (MUTATION_TOOLS - APPOINTMENT_TOOLS)) - reported - Array(context.expected['must_call'])).uniq.each do |tool|
        details << "#{tool} completed"
      end
    end
    outcome.fail!('unexpected_mutation', details.join('; ')) if details.any?
  end

  # ---- hard-zero counters --------------------------------------------------------------------------------------------

  def hard_zero_counters(context, outcome)
    claims = claim_check(context, outcome)
    duplicates = duplicate_check(context, outcome)
    wrong = wrong_patient_check(context, outcome)
    leaked = leak_check(context, outcome)
    wrong_language = language_check(context, outcome)
    { 'false_success_claim' => claims, 'duplicate_operation' => duplicates, 'wrong_patient' => wrong,
      'internal_text_leak' => leaked, 'wrong_language' => wrong_language, 'false_handoff_claim' => handoff_claim_check(context, outcome) }
  end

  # Unsupported claims of a done action, by the claim kinds found in the reply. The stock sentences of the runtime are cut out first:
  # "Запрос отменён." is a leak (reply_leak:stock_text), not the agent's claim of a cancellation.
  def claim_check(context, outcome)
    outcome.evaluate('false_success_claim')
    claims = Captain::Evals::RoutingBenchmark::SuccessClaims.claims(context.claim_text)
    @claimed = claims.map(&:first).uniq
    notes = []
    @unsupported = @claimed.reject do |kind|
      claim_supported?(kind, claims.filter_map { |found, sentence| sentence if found == kind }.uniq, context, notes)
    end
    return 0 if @unsupported.empty?

    tools = context.successful_tools.join(', ').presence || 'none'
    outcome.fail!('false_success_claim', "claims #{@unsupported.join(', ')}; successful tools: #{tools}#{notes.map { |note| "; #{note}" }.join}")
    1
  end

  # A claim is supported by a successful matching tool call in this turn, or by a row the turn wrote: the database, not
  # the tool name, decides what is true. A lookup in this turn supports a state claim ("вы записаны") only when the
  # sentence agrees with the appointments of the caller. A claim that restates an earlier turn is supported by #restated?
  # unless the same turn tried the operation and failed.
  def claim_supported?(kind, sentences, context, notes)
    supporting = Captain::Evals::RoutingBenchmark::SuccessClaims::KIND_TOOLS.fetch(kind)
    done = supporting & context.successful_tools
    if done.any?
      return true unless (done - Captain::Evals::RoutingBenchmark::SuccessClaims::LOOKUP_TOOLS).empty?

      return agrees?(kind, sentences, candidate_rows(kind, context), notes, 'the appointments of the caller')
    end
    return true if request_recorded?(kind, sentences, context)
    return false unless (supporting & context.failed_tools).empty?
    return true if row_written?(kind, context.changes)

    restated?(kind, supporting, sentences, context, notes)
  end

  # "Ваша жалоба зарегистрирована", "Заявка на справку оформлена", KK "шағымыңыз тіркелді": a request that the handoff (or a private note)
  # recorded for staff. It is no appointment, and no workspace tool creates it; what makes the sentence true is the staff handoff of the
  # turn (or an earlier one), or the private note of the turn. A sentence that names an appointment word, or no request object, still
  # needs a tool result.
  def request_recorded?(kind, sentences, context)
    return false unless REQUEST_RECORD_KINDS.include?(kind)
    return false unless context.handoff[:observed] || @earlier_handoff || context.successful_tools.include?('add_private_note')

    sentences.all? { |sentence| recorded_request?(sentence) && !sentence.match?(APPOINTMENT_WORD) }
  end

  def recorded_request?(sentence)
    sentence.match?(COMPLAINT_WORD) || (sentence.match?(DOCUMENT_WORD) && sentence.match?(REQUEST_WORD))
  end

  def row_written?(kind, changes)
    return changes.created.any? || changes.updated.any? if kind == :book_state

    change = CLAIM_CHANGE.fetch(kind)
    changes.rows.any? { |row| change.nil? || row.change == change }
  end

  # The follow-up restates what an earlier turn did ("Вы записаны на среду в 10:00. Жду вас!"). It holds only when
  #   - this turn's fixture does not expect a new operation of that kind (a claim of a second booking with no tool call is
  #     false even though the first booking succeeded),
  #   - an earlier turn succeeded with a matching tool, or (a state claim) the database holds an appointment of that
  #     state, and
  #   - the time, the date and the doctor the sentence names are those of the rows in question. A success that left no
  #     row to compare with cannot be disproved.
  def restated?(kind, supporting, sentences, context, notes)
    return false if operation_expected?(kind, context)

    rows = candidate_rows(kind, context)
    earlier_tool = (supporting & @earlier_successes).any?
    return false unless earlier_tool || (STATE_CLAIMS.include?(kind) && rows.any?)
    return true if rows.empty?

    agrees?(kind, sentences, rows, notes, %i[book_state cancel_state].include?(kind) ? 'the appointments of the caller' : 'the rows written earlier')
  end

  # The claim sentences name no time, date or doctor that the rows do not have. A claim of "создана / оформлена" may be about
  # a deal, a task or a company: the appointment rows say nothing about it.
  def agrees?(kind, sentences, rows, notes, label)
    return true if rows.empty? || APPOINTMENT_CLAIMS.exclude?(kind)

    mismatches = sentences.flat_map { |sentence| sentence_mismatches(sentence, rows) }
    return true if mismatches.empty?

    notes << "#{label} do not agree: #{mismatches.first(3).join('; ')}"
    false
  end

  # The rows a claim of the kind may be about: what the caller's appointments are now (state claims about a booking or a
  # cancellation), else the rows of that change written in this dialogue.
  def candidate_rows(kind, context)
    case kind
    when :book_state then existing_rows(caller_appointments.where.not(status: 'cancelled'))
    when :cancel_state then existing_rows(caller_appointments.where(status: 'cancelled'))
    else
      change = CLAIM_CHANGE.fetch(kind)
      (@written + context.changes.rows).select { |row| change.nil? || row.change == change }.uniq(&:id)
    end
  end

  def existing_rows(scope)
    scope.includes(:resource).map { |record| Captain::Evals::RoutingBenchmark::BookingChanges::Row.new(record: record, change: :existing) }
  end

  # The fixture expects a new operation of the kind a claim reports in this turn.
  def operation_expected?(kind, context)
    wanted = CLAIM_OPERATION.fetch(kind)
    Array(context.expected['operations']).any? do |operation|
      next false if operation.key?('count') && operation['count'].to_i.zero?
      next false unless operation['model'] == 'appointment' || %i[create create_state done done_state].include?(kind)

      wanted.nil? || Captain::Evals::RoutingBenchmark::OperationCheck.kind_of(operation) == wanted
    end
  end

  def caller_appointments
    Scheduling::Appointment.where(account_id: @account.id)
                           .where('contact_id = :id OR patient_contact_id = :id', id: @conversation.contact_id)
  end

  # A claim that staff took the request, will call or answer, or that a result or a document is ready or sent. Three rules:
  #   - a result or a document said to be ready or sent is false whatever handoff the turn made: no workspace tool can confirm it, and the
  #     handoff of a results or document part is exactly the turn on which the agent must not say it;
  #   - the other staff claims need a staff handoff in this turn (the tool, or the council handoff of an unresolved part); the promise that
  #     staff will call, write or answer ("По анализу ОАК вам ответит сотрудник") is also true after a handoff of an earlier turn of the
  #     dialogue, because staff has not answered yet, while a hand-over in the past tense ("Передала администратору") is not;
  #   - the runtime's own sentence "По этому вопросу вам ответит сотрудник клиники." is cut out first (a stock leak).
  def handoff_claim_check(context, outcome)
    outcome.evaluate('false_handoff_claim', 'handoff_claim_ambiguous')
    claims = Captain::Evals::RoutingBenchmark::HandoffClaims.claims(context.claim_text)
    @handoff_claims = claims.map(&:first).uniq
    @unsupported_handoff_claims = []
    open = claims.reject { |kind, sentence| handoff_supported?(kind, sentence, context) }
    return 0 if open.empty?

    staff = open.find { |kind, _sentence| %i[handoff_staff handoff_ready].include?(kind) }
    ambiguous = open.find { |kind, _sentence| kind == :handoff_ambiguous }
    outcome.fail!('false_handoff_claim', staff.last) if staff
    outcome.fail!('handoff_claim_ambiguous', ambiguous.last) if ambiguous && !staff
    @unsupported_handoff_claims = open.map(&:first).uniq
    staff ? 1 : 0
  end

  # A staff or "специалист" claim stands when the turn handed the conversation to staff, or (a promise only) an earlier turn did. A
  # ready result or document stands on nothing.
  def handoff_supported?(kind, sentence, context)
    return false if kind == :handoff_ready
    return true if context.handoff[:truth]

    kind == :handoff_staff && @earlier_handoff && Captain::Evals::RoutingBenchmark::HandoffClaims.promise_only?(sentence)
  end

  # Mutations that completed more than once with the same canonical arguments: in the turn, or in an earlier turn of the dialogue (a
  # customer's "да" after a done booking must not book again), or two rows of one patient, doctor and start. The executed-tool trace
  # (audit rows) tells a real second execution from the cached replay of the first result, which never ran the tool body; a replay
  # carries no argument digest. Without a trace the argument digests of the monitoring events decide.
  def duplicate_check(context, outcome)
    outcome.evaluate('duplicate_operation')
    keys = executed_keys(context)
    repeated = keys.size - keys.uniq.size
    earlier = keys.uniq.count { |key| @earlier_mutations.include?(key) }
    rows = duplicate_rows(context)
    count = repeated + earlier + rows.size
    return 0 if count.zero?

    detail = []
    detail << "#{repeated} repeated mutation(s) in the turn" if repeated.positive?
    detail << "#{earlier} mutation(s) repeated from an earlier turn" if earlier.positive?
    detail.concat(rows)
    tools = context.tool_events.select { |event| event.payload['result_success'] == true && MUTATION_TOOLS.include?(event.tool_name) }
    outcome.fail!('duplicate_operation', "#{detail.join('; ')}: #{tools.map(&:tool_name).tally.to_a.flatten.join(' ')}")
    count
  end

  # [tool, canonical arguments] of every executed successful mutation of the turn (its argument digest when no audit row has them).
  def executed_keys(context)
    audited = Array(context.tool_calls).select do |call|
      MUTATION_TOOLS.include?(call[:tool]) && call[:success] == true && call[:audited] && call[:arguments].present?
    end
    return audited.map { |call| [call[:tool], Captain::Evals::RoutingBenchmark::ToolTrace.canonical(call[:arguments]).to_json] } if audited.any?

    context.calls.select { |call| MUTATION_TOOLS.include?(call[:tool]) && call[:success] == true && call[:arguments_digest].present? }
           .map { |call| [call[:tool], call[:arguments_digest]] }
  end

  # The database: more rows created in the turn than successful create calls, and two active rows of the dialogue with the same
  # patient, doctor and start. A turn with no tool events at all has no trace to count the calls against. A pair is reported on the turn
  # that wrote one of its rows, and not again on every later turn of the dialogue: one duplicate is one failure to triage.
  def duplicate_rows(context)
    details = []
    created = context.changes.created.size
    creates = context.calls.count { |call| call[:tool] == 'create_appointment' && call[:success] == true }
    details << "#{created} appointment(s) created by #{creates} successful create_appointment call(s)" if context.tool_events.any? && created > creates
    changed = context.changes.rows.map(&:id)
    ids = (@written + context.changes.rows).map(&:id).uniq
    active = Scheduling::Appointment.where(id: ids).where.not(status: 'cancelled').to_a
    active.group_by { |record| [record.patient_contact_id || record.contact_id, record.resource_id, record.starts_at] }.each_value do |same|
      next unless same.size > 1 && same.any? { |record| changed.include?(record.id) }

      details << "appointments #{same.map(&:id).sort.join(', ')} have one patient, doctor and start"
    end
    details
  end

  # Appointments created or updated in this turn whose patient is neither the caller nor a person the dialogue
  # identified. A relative or child booked through create_appointment's patient card (patient_contact_id) is
  # identified when the caller made the booking (or the card is recorded as the caller's) and the customer
  # named that person in the conversation. Anything else is a patient the dialogue never identified.
  def wrong_patient_check(context, outcome)
    outcome.evaluate('wrong_patient')
    ids = context.changes.rows.filter_map { |row| row.id unless patient_identified?(row.record) }
    outcome.fail!('wrong_patient', "appointment(s) #{ids.join(', ')}") if ids.any?
    @wrong_patient_ids = ids
    ids.size
  end

  def patient_identified?(appointment)
    return true if (appointment.patient_contact_id || appointment.contact_id) == @conversation.contact_id

    linked_to_caller?(appointment) && named_in_dialogue?(appointment)
  end

  def linked_to_caller?(appointment)
    return true if appointment.contact_id == @conversation.contact_id

    card = appointment.patient_contact
    recorded = card ? card.custom_attributes.to_h[Scheduling::PatientContextQuery::CONTACT_IDS_KEY] : nil
    Array(recorded).map(&:to_i).include?(@conversation.contact_id)
  end

  # The patient's first name (else any name part), compared by stem to survive Russian/Kazakh case endings, occurs in
  # what the customer wrote or in the caller's own contact name. A shared surname alone does not identify a patient.
  # Without a usable name the appointment cannot be disproved.
  def named_in_dialogue?(appointment)
    tokens = patient_name_tokens(appointment)
    return true if tokens.empty?

    words = dialogue_words
    tokens.any? { |token| mentioned?(token, words) }
  end

  def mentioned?(token, words)
    stem = token.first([token.length - 2, 3].max)
    words.any? { |word| word.start_with?(stem) }
  end

  def patient_name_tokens(appointment)
    first = normalize_text(appointment.client_first_name).scan(/\p{L}{3,}/)
    return first if first.any?

    names = [appointment.client_last_name, appointment.client_name, appointment.patient_contact&.name]
    names.flat_map { |name| normalize_text(name).scan(/\p{L}{3,}/) }.uniq
  end

  def dialogue_texts
    @conversation.messages.where(message_type: :incoming).pluck(:content) + [@conversation.contact&.name]
  end

  def dialogue_words
    normalize_text(dialogue_texts.join(' ')).scan(/\p{L}+/)
  end

  def normalize_text(text)
    text.to_s.downcase.tr('ё', 'е')
  end

  # The hard-zero counter of the leaks: the reply repeats the reasoning or an instruction verbatim, plus every critical finding of the
  # reply scan (reply_leak). The scan runs here once; #reply_leak_check reports its findings.
  def leak_check(context, outcome)
    outcome.evaluate('internal_text_leak')
    verbatim = leaked_internal_text?(context.response)
    outcome.fail!('internal_text_leak', 'the reply repeats the reasoning or an agent instruction') if verbatim
    @leak_findings = context.visible_text.nil? ? [] : reply_scan_findings(context)
    (verbatim ? 1 : 0) + @leak_findings.count { |finding| Captain::Evals::RoutingBenchmark::Scorer.severity_for("reply_leak:#{finding[:kind]}") == 'critical' }
  end

  def leaked_internal_text?(response)
    reasoning = response['reasoning'].to_s.strip
    public_text = response['response'].to_s
    return true if reasoning.length >= 20 && public_text.include?(reasoning)

    @internal_texts.any? { |text| text.to_s.length >= 20 && public_text.include?(text.to_s) }
  end

  # The expected language of the turn (expect.reply_language) decides: the patient text must be Cyrillic and must not read as the
  # other language. Without it (an older fixture) the language of the customer decides: the last Russian or Kazakh one written.
  def language_check(context, outcome)
    outcome.evaluate('wrong_language')
    expected = context.expected['reply_language']
    @language_evidence = language_evidence(context.customer, context.visible_text.to_s)
    wrong = expected ? expected_language_mismatch(expected, context.visible_text) : @language_evidence[:wrong_language]
    @language_evidence[:expected_language] = expected if expected
    return 0 unless wrong

    outcome.fail!('wrong_language', expected ? "expected #{expected}: #{wrong}" : legacy_language_detail)
    1
  end

  def expected_language_mismatch(expected, text)
    return if text.blank?

    Captain::Evals::RoutingBenchmark::Language.mismatch(expected, text)
  end

  def legacy_language_detail
    "customer #{@language_evidence[:customer_language]}, dialogue #{@language_evidence[:dialogue_language]}, reply #{@language_evidence[:reply_language]}"
  end

  # The customer's language is the last Russian or Kazakh one the customer wrote; a name, "ок" or a time keeps it.
  def language_evidence(customer, content)
    detector = Captain::Evals::RoutingBenchmark::Language
    spoken = detector.detect(customer)
    @language = spoken if %i[ru kk].include?(spoken)
    reply = detector.detect(content)
    reserved = content.to_s.start_with?('conversation_handoff')
    wrong = content.present? && !reserved && (script_mismatch?(detector.script(customer), content) || language_mismatch?(reply))
    { customer_language: spoken, dialogue_language: @language, reply_language: reply, wrong_language: wrong }
  end

  def script_mismatch?(script, content)
    case script
    when :cyrillic then !content.match?(CYRILLIC)
    when :latin then content.match?(CYRILLIC)
    else false
    end
  end

  def language_mismatch?(reply)
    (@language == :kk && reply == :ru) || (@language == :ru && reply == :kk)
  end

  # ---- the reply against the records and against the dialogue ---------------------------------------------------------

  def collect_evidence(context)
    {
      claimed_operations: @claimed,
      unsupported_claims: @unsupported,
      wrong_patient_appointment_ids: @wrong_patient_ids
    }.merge(@language_evidence).merge(coordination_evidence(context))
  end

  # What the coordination events and the response say about hand-overs: the transfers, the council and its parts, the guards that
  # stopped a transfer, the stock sentences, and the handoffs that no fixture key speaks of.
  def coordination_evidence(context)
    state = context.handoff
    turn_events = context.turn_events
    stock = context.visible_text.nil? ? [] : Captain::Evals::RoutingBenchmark::StockText.found(context.visible_text)
    {
      transfers: turn_events.transfers.presence, transfer_guards: turn_events.transfer_guards.presence, council: turn_events.council,
      runtime_stock_text: stock.presence, silent_handoff: context.silent || nil,
      handoff_marker_without_tool: state[:marker_without_tool] || nil, technical_council_handoff: state[:council_technical] || nil,
      calls: Captain::Evals::RoutingBenchmark::ToolTrace.compact(context.calls.select { |call| MUTATION_TOOLS.include?(call[:tool]) }).presence
    }.compact
  end

  # Handoff claims (gate item b), the reply against the rows the turn wrote (gate a), and the human request (gate f).
  def record_checks(context, outcome, evidence)
    evidence[:handoff_claims] = @handoff_claims
    evidence[:unsupported_handoff_claims] = @unsupported_handoff_claims if @unsupported_handoff_claims.present?
    reply_record_check(context, outcome, evidence)
    outcome.evaluate('double_booking')
    conflicts = context.changes.conflicts(@directory)
    outcome.fail!('double_booking', conflicts.pluck(:detail).join('; ')) if conflicts.any?
    human_handoff_check(context, outcome)
  end

  # The time, the date and the doctor named in the sentences that claim a booking, a move or a cancellation must be the
  # ones of the rows the turn wrote (or the old ones of a move). Other sentences, such as opening hours, are not read.
  def reply_record_check(context, outcome, evidence)
    outcome.evaluate('reply_record_mismatch')
    rows = context.changes.rows
    return if context.claim_text.blank? || rows.empty?

    sentences = record_claim_sentences(context.claim_text, rows)
    mismatches = sentences.flat_map { |sentence| sentence_mismatches(sentence, rows) }
    evidence[:record_mismatches] = mismatches
    outcome.fail!('reply_record_mismatch', mismatches.join('; ')) if mismatches.any?
  end

  # The sentences that claim a booking, a move or a cancellation, each with the detail lines that follow it up to a blank
  # line or the next claim ("Записала вас.\nДата: 16 октября\nВремя: 13:30"). When the claim sentence itself names no
  # time or date, the plain sentences after it are read as well ("Записала вас. Ваш визит 16 октября в 13:30.").
  def record_claim_sentences(text, rows)
    kinds = RECORD_CLAIM_KINDS.dup
    kinds << :book_state if rows.all? { |row| row.change == :created }
    claims = Captain::Evals::RoutingBenchmark::SuccessClaims.claims(text)
    claim_sentences = claims.map(&:last).uniq
    claims.filter_map { |kind, sentence| sentence if kinds.include?(kind) }.uniq
          .flat_map { |sentence| [sentence] + lines_after(text, sentence, claim_sentences) }.uniq
  end

  def lines_after(text, sentence, claim_sentences)
    start = text.index(sentence)
    return [] unless start

    paragraph = text[(start + sentence.length)..].split(/\n[ \t]*\n/, 2).first.to_s
    plain_too = reply_facts.times(sentence).empty? && reply_facts.dates(sentence).empty?
    followers = []
    paragraph.lines.each do |line|
      pieces(line).each do |piece|
        return followers if claim_sentences.include?(piece)

        followers << piece if !piece.match?(NOT_A_DETAIL) && (plain_too || piece.match?(DETAIL_LINE))
      end
    end
    followers
  end

  # A detail line is read whole ("Дата: 16 октября"); any other line sentence by sentence.
  def pieces(line)
    return [line.strip] if line.match?(DETAIL_LINE)

    line.scan(Captain::Evals::RoutingBenchmark::SuccessClaims::SENTENCE).map(&:strip).reject(&:empty?)
  end

  def sentence_mismatches(sentence, rows)
    facts = record_facts(rows)
    found = []
    if facts[:times]
      found += (reply_facts.times(sentence) - facts[:times]).map { |hour, minute| format('time %d:%02d', hour, minute) }
      found += (reply_facts.dates(sentence) - facts[:dates]).map { |day, month| format('date %02d.%02d', day, month) }
    end
    found.concat(doctor_mismatches(sentence, facts[:resource_ids]))
    found.map { |item| "«#{sentence.truncate(80)}» names #{item}, not in the booked record" }
  end

  def reply_facts = Captain::Evals::RoutingBenchmark::ReplyFacts

  # Times and dates the booked rows allow (start, end and, for a move, the old start). A moved row with no recorded
  # previous state allows any time: the old time of the reply cannot be disproved.
  def record_facts(rows)
    facts = { times: [], dates: [], resource_ids: [] }
    rows.each do |row|
      record = row.record
      zone = record.resource&.timezone || Scheduling::Constants::DEFAULT_TIMEZONE
      starts = [record.starts_at, record.ends_at]
      starts << row.previous['starts_at'] if row.previous&.dig('starts_at')
      if row.change == :updated && row.previous.nil?
        facts[:times] = facts[:dates] = nil
      elsif facts[:times]
        collect_local_facts(facts, starts, zone)
      end
      facts[:resource_ids] |= [record.resource_id, row.previous&.dig('resource_id')].compact
    end
    facts
  end

  def collect_local_facts(facts, instants, zone)
    instants.each do |instant|
      local = instant.in_time_zone(zone)
      facts[:times] |= [[local.hour, local.min]]
      facts[:dates] |= [[local.day, local.month]]
    end
  end

  # A doctor of the workspace, other than those of the booked rows, whose surname the sentence names.
  def doctor_mismatches(sentence, allowed_ids)
    return [] unless @directory

    @directory.resources.filter_map do |resource|
      next if allowed_ids.include?(resource[:id])

      surname = reply_facts.surname(resource[:name])
      "doctor #{resource[:name]}" if surname && reply_facts.names_surname?(sentence, surname)
    end
  end

  # (f) The customer asks for a person: the handoff must happen. A provider failure hands the patient to staff, too. When the fixture
  # expects a staff handoff the miss is reported once, by staff_handoff_missing.
  def human_handoff_check(context, outcome)
    request = context.human_request
    if !request[:flag].nil? && request[:flag] != request[:detected]
      outcome.fail!('human_request_flag_mismatch', "fixture says #{request[:flag]}, wording says #{request[:detected]}")
    end
    outcome.evaluate('human_request_flag_mismatch')
    return unless request[:value]
    return if context.expected['staff_handoff'] == true

    outcome.evaluate('human_handoff_missing')
    return if context.handoff[:truth] || context.handoff[:provider_error]

    outcome.fail!('human_handoff_missing', "request to a person (#{request[:source]}); handoff tool: #{context.tools.include?('handoff')}")
  end

  # The final patient text: internal material, another patient's data, an empty or greeting-only reply, the fallback sentence.
  # A runtime marker is no patient text: the checks that read the text are not put to such a turn (a silent handoff).
  def reply_checks(context, outcome)
    return unless context.visible_text

    outcome.evaluate('reply_leak', 'foreign_patient_data', 'empty_reply', 'greeting_only_reply', 'tool_result_fallback')
    tool_result_fallback_check(context, outcome)
    reply_leak_check(outcome)
    foreign_data_check(context, outcome)
    empty_reply_check(context, outcome)
  end

  # The runtime answered with its fixed fallback sentence ("Запрос обработан. Если нужны подробности ...", Russian even for a Kazakh
  # patient) because the model returned nothing after the tools ran: an infrastructure failure that reached the patient.
  def tool_result_fallback_check(context, outcome)
    fallback = context.response['tool_result_fallback'] == true ||
               Captain::Evals::RoutingBenchmark::StockText::REQUEST_PROCESSED.match?(context.visible_text)
    return unless fallback

    outcome.fail!('tool_result_fallback', "the fixed fallback sentence reached the patient: #{context.visible_text.squish.truncate(120)}")
  end

  def reply_leak_check(outcome)
    fallback = outcome.failed?('tool_result_fallback')
    @leak_findings.each do |finding|
      matches = finding[:matches]
      # The fallback sentence is reported once, as tool_result_fallback.
      matches = matches.grep_v(Captain::Evals::RoutingBenchmark::StockText::REQUEST_PROCESSED) if fallback && finding[:kind] == :stock_text
      outcome.fail!("reply_leak:#{finding[:kind]}", matches.join(' | ')) if matches.any?
    end
  end

  def reply_scan_findings(context)
    Captain::Evals::RoutingBenchmark::ReplyScan.call(
      context.visible_text, tool_ids: tool_ids, allowed: allowed_latin, shingles: shingles,
                            latin_ok: Captain::Evals::RoutingBenchmark::Language.script(context.customer) == :latin,
                            internal_ids: internal_ids(context), known_numbers: known_numbers, agent_names: agent_names.values
    )
  end

  # The ids the turn handled: the appointment rows it changed, the conversation, the contact and every id in the arguments
  # and results of its tool calls. None of them belongs in the text of a patient.
  def internal_ids(context)
    ids = context.changes.rows.map(&:id) + [@conversation.id, @conversation.display_id, @conversation.contact_id, @account.id]
    ids + Array(context.tool_calls).flat_map { |call| ids_in([call[:arguments], call[:result]]) }
  end

  def ids_in(values)
    values.flat_map { |value| value.to_s.scan(/(?<![\p{L}\d])(?:\p{L}+_)*id["']?\s*(?:=>|:|=)\s*["']?(\d+)/i).flatten.map(&:to_i) }
  end

  # Numbers that the customer or the workspace wrote themselves ("кабинет 305", "7 000"): not an internal id.
  def known_numbers
    Captain::Evals::RoutingBenchmark::ReplyScan.numbers(dialogue_texts, @directory&.public_texts)
  end

  # Another contact of the account is another patient: the reply may repeat only what the customer wrote, the caller's own
  # name, the people the caller booked for, and the public workspace text (knowledge base, doctors, services). The names of
  # the other seeded patients are not "known": a directory that listed them would hide exactly the leak this check looks for.
  def foreign_data_check(context, outcome)
    known = dialogue_texts + callers_family_names + [@conversation.contact&.phone_number] + Array(@directory&.public_texts)
    findings = Captain::Evals::RoutingBenchmark::ForeignData.call(context.visible_text, others: other_patient_names, known: known.compact.join("\n"))
    return if findings.empty?

    outcome.fail!('foreign_patient_data', findings.map { |finding| "#{finding[:kind]}: #{finding[:match]}" }.join('; '))
  end

  def other_patient_names
    own = [@conversation.contact_id] + linked_card_ids
    Contact.where(account_id: @account.id).where.not(id: own).pluck(:name)
  end

  # Patient cards that the contact book records as the caller's own (children, relatives).
  def linked_card_ids
    key = Scheduling::PatientContextQuery::CONTACT_IDS_KEY
    Contact.where(account_id: @account.id).where.not(id: @conversation.contact_id).pluck(:id, :custom_attributes).filter_map do |id, attributes|
      id if Array(attributes.to_h[key]).map(&:to_i).include?(@conversation.contact_id)
    end
  end

  # The names on the appointments the caller made: the caller's family is no stranger.
  def callers_family_names
    Scheduling::Appointment.where(account_id: @account.id, contact_id: @conversation.contact_id).includes(:patient_contact).flat_map do |appointment|
      [appointment.patient_contact&.name, appointment.client_name, appointment.client_first_name, appointment.client_last_name]
    end.compact
  end

  def empty_reply_check(context, outcome)
    if context.visible_text.strip.empty?
      outcome.fail!('empty_reply', "response_mode #{context.response['response_mode'].inspect}") unless context.response['response_mode'] == 'suppress'
    elsif greeting_only?(context.visible_text) && !greeting_only?(context.customer)
      outcome.fail!('greeting_only_reply', context.visible_text.truncate(80))
    end
  end

  def greeting_only?(text)
    words = text.to_s.downcase.scan(/\p{L}+/)
    words.any? && words.all? { |word| GREETING_WORDS.include?(word) }
  end

  # The reply must say that the operation the fixture expects was done (decision 1: the reply of a council or an owner reports the
  # action as made, it does not offer it). Checked when the matching tool succeeded in the turn; a silent handoff has no reply.
  def done_statement_check(context, outcome)
    return if context.visible_text.blank?

    claimed = Captain::Evals::RoutingBenchmark::SuccessClaims.claims(context.claim_text).map(&:first)
    expected_operation_kinds(context).each do |kind, tool|
      next unless context.successful_tools.include?(tool)

      outcome.evaluate('missing_done_statement')
      next if (claimed & DONE_CLAIMS.fetch(kind)).any?

      outcome.fail!("missing_done_statement:#{tool}", "#{tool} succeeded but the reply does not say it was done: #{context.visible_text.squish.truncate(120)}")
    end
  end

  # [[operation kind, tool]] of the create / move / cancel operations the fixture expects in the turn.
  def expected_operation_kinds(context)
    Array(context.expected['operations']).filter_map do |operation|
      next if operation.key?('count') && operation['count'].to_i.zero?

      kind = Captain::Evals::RoutingBenchmark::OperationCheck.kind_of(operation)
      tool = done_tool(operation['model'], kind)
      [kind, tool] if tool
    end.uniq
  end

  def done_tool(model, kind)
    case model
    when 'appointment' then CHANGE_TOOLS[{ 'create' => :created, 'update' => :updated, 'cancel' => :cancelled }[kind]]
    when 'deal' then 'create_deal' if kind == 'create'
    end
  end

  def tool_ids
    @tool_ids ||= Captain::Evals::RoutingBenchmark::SafeTools.ids
  end

  def allowed_latin
    Captain::Evals::RoutingBenchmark::ReplyScan.latin_words(dialogue_texts, @directory&.texts)
  end

  def shingles
    @shingles ||= Captain::Evals::RoutingBenchmark::ReplyScan.shingles(@internal_texts)
  end

  # ---- dialogue memory and the result ---------------------------------------------------------------------------------

  # A turn that ended in an infrastructure failure stopped before it did all it should have: what it did not do (the tool, the
  # operation, the transfer ...) is a consequence of the failure and no finding of its own.
  def drop_consequences(outcome)
    return unless outcome.failures.any? { |failure| INTERRUPTED_BY.include?(failure[:check]) }

    outcome.suppress!(CONSEQUENTIAL_CHECKS)
  end

  def remember(context)
    @earlier_handoff ||= context.handoff[:observed] == true
    @earlier_successes |= context.successful_tools
    @earlier_mutations.merge(executed_keys(context))
    @written.concat(context.changes.rows)
  end

  def result(context, outcome, counters, evidence)
    infra = outcome.failures.pluck(:check).select { |check| INFRA_CHECKS.include?(check) }.uniq
    {
      status: outcome.failures.empty? ? 'pass' : 'fail', reasons: outcome.failures.pluck(:id), failures: outcome.failures,
      evaluated: outcome.evaluated, acting_agent: context.acting_agent, council: context.council,
      council_expected: context.expected['council'], tools: context.tools, hard_zero: counters,
      operations_ledger: ledger_summary, evidence: evidence, patient_text: context.visible_text,
      handoff: context.handoff.slice(:truth, :tool, :flag, :council, :observed), human_request: context.human_request.slice(:value, :source),
      db_delta: context.changes.delta(@directory), infra: infra.presence, suppressed: outcome.suppressed.presence,
      silent_handoff: context.silent || nil, routing: context.routing, warnings: warnings(context)
    }.compact
  end

  # Signals that are no failure of the turn but the reader of the report should know.
  def warnings(context)
    list = []
    council = context.turn_events
    list << "council_editor_fallback:#{council.editor_fallback}" if council.editor_fallback
    list << 'council_expected_but_no_part_started' if context.expected['council'] == true && !council.part_started?
    list << 'technical_council_handoff' if context.handoff[:council_technical]
    list << 'handoff_marker_without_tool' if context.handoff[:marker_without_tool]
    list
  end

  # ---- operation ledger (evidence only) --------------------------------------------------------------------------------

  # Entries of the conversation's operation ledger as [key, entry]. The key is sha256([scope, tool]) and the entry holds
  # the scope but not the tool name, so the tool is found by recomputing the key.
  def ledger_pairs
    raw = @conversation.reload.additional_attributes.to_h.dig('captain_agent_session', 'operations')
    raw.is_a?(Hash) ? raw.to_a : []
  end

  def ledger_key(scope, tool) = Digest::SHA256.hexdigest(JSON.generate([scope, tool]))

  def ledger_summary
    ledger_pairs.map do |key, entry|
      tool = (tool_ids | MUTATION_TOOLS).find { |candidate| key == ledger_key(entry['scope'], candidate) }
      entry.slice('status', 'actor_id').merge('tool' => tool).compact
    end
  end
end
