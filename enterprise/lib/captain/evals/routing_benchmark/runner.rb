# frozen_string_literal: true

require 'active_support/testing/time_helpers'

require 'json'

# Runs the dialogues of the fixtures through the real agent runtime and scores every turn. Besides the customer turns it plays the
# part of the response builder that the runtime depends on between two turns (ResponseBuilderJob), because the runner does not
# deliver anything:
#   - a public reply is recorded as delivered with every part it reports (`part_refs`), or the next turn would be told to announce an
#     old booking again and the repair of a linked follow-up would never fire;
#   - an observed staff handoff, and a failed turn (the provider error response, a technical failure of a tool, the technical handoff of a
#     council part), leave the conversation `open` (Conversation#bot_handoff!): staff owns it until the next turn of the
#     fixture says `staff: {status: pending}`, which gives it back to the AI. A turn run on an open conversation with no such key is
#     scored as usual and carries the warning ai_answered_while_staff_owned;
#   - the history of the model gets the replies the customer saw, and nothing else: no handoff marker, no provider error response, no
#     suppressed reply.
class Captain::Evals::RoutingBenchmark::Runner
  include ActiveSupport::Testing::TimeHelpers

  MODEL = 'openai/gpt-6-luna'
  class BudgetExceeded < StandardError; end

  # A turn whose request left no provider usage row (a failed or aborted call) is counted; several such turns stop
  # the run, because the budget can no longer be trusted.
  MAX_USAGE_GAPS = 3
  REPLY_LIMIT = 4000
  FACTS_LIMIT = 4000
  REASONS_LIMIT = 300
  # The judge runs on standard processing, like the council editor (feature captain_agent, no tools). The `editor` feature is bound to
  # the Flex service tier, which the provider switches off under load ("Flex processing is temporarily unavailable"): on DEV that
  # answered about 40% of the judge calls with an error and every one of them became judge_unavailable.
  JUDGE_FEATURE = :captain_agent
  # Reasoning effort of the judge: without any, the judge misread replies that do ask for the day (short_fragments_12).
  JUDGE_THINKING_EFFORT = 'low'
  # The output limit of a judge call. The reasoning of the model counts against it, so a limit that only fits the short JSON verdict
  # would cut the answer off after the reasoning (finish_reason `length`, no content); the verdict itself is a few dozen tokens.
  JUDGE_MAX_TOKENS = 4000
  # A judge call that failed is asked again at most twice, after a short pause that grows with every attempt.
  JUDGE_RETRIES = 2
  JUDGE_PAUSE_SECONDS = 2
  # The required check of a turn that the judge could not give a verdict for (see #judge_unusable).
  NOT_EVALUATED_JUDGE = 'judge'
  STAFF_OWNED_WARNING = 'ai_answered_while_staff_owned'

  # An answer of the judge that is no verdict. It carries the finish_reason of the call: `length` says the output limit cut it off.
  class UnusableVerdict < JSON::ParserError
    attr_reader :finish_reason

    def initialize(message, finish_reason = nil)
      super(message)
      @finish_reason = finish_reason
    end
  end

  # triage: path of an earlier report (or label file) whose triage records a person filled in; see Triage.load.
  # progress: an IO that gets one line after every dialogue (see #report_progress), flushed at once; nil prints nothing.
  def initialize(fixtures:, runs: 3, model: MODEL, reasoning: 'none', budget_usd:, out:, judge: false, triage: nil, progress: nil)
    @fixtures, @runs, @model, @reasoning = fixtures, Integer(runs), model, reasoning
    @budget_usd, @out, @judge = BigDecimal(budget_usd.to_s), out, judge
    @triage = triage
    @progress = progress
    raise ArgumentError, 'Only openai/gpt-6-luna is allowed' unless @model == MODEL
    raise ArgumentError, 'REASONING must be none or low' unless %w[none low].include?(@reasoning)
    raise ArgumentError, 'RUNS and BUDGET_USD must be positive' unless @runs.positive? && @budget_usd.positive?
  end

  def call
    Captain::Evals::RoutingBenchmark::Guard.check!
    Captain::Evals::RoutingBenchmark::Guard.restrict_http!
    raise ArgumentError, 'OUT already exists' if File.exist?(@out) || File.exist?("#{@out}.md")
    raise ArgumentError, 'OUT directory does not exist' unless File.directory?(File.dirname(@out))
    paths = Dir.glob(@fixtures)
    raise ArgumentError, 'No fixtures matched FIXTURES' if paths.empty?

    labels = Captain::Evals::RoutingBenchmark::Triage.load(@triage)
    fixtures = paths.map { |path| [path, Captain::Evals::RoutingBenchmark::Fixture.load(path)] }
    @spent = BigDecimal('0')
    @usage_gaps = 0
    @cases = []
    @aborted = false
    @silent_handoff = nil
    @silent_handoff_error = nil
    @dialogues_total = fixtures.sum { |_path, fixture| fixture.dialogues.size } * @runs
    @dialogues_done = 0
    fixtures.each do |path, fixture|
      @runs.times do |run_index|
        execute_fixture(path, fixture, run_index + 1)
      rescue BudgetExceeded => e
        @aborted = true
        @abort_reason = e.message
        break
      end
      break if @aborted
    end
    report = build_report(labels)
    write_report(report)
    report
  end

  # The judge of a turn stored in an earlier report (see Rejudge): the prompt and the call of a live run, with the facts of the fixture
  # of the case. Returns the scored turn with the new verdict and what the call cost, or nil when the turn is not judged (no rubric,
  # nothing to read).
  def judge_stored(account, fixture, dialogue, turn, response, scored, history, tool_calls, earlier_handoffs: 0)
    return unless judge_turn?(dialogue, turn, scored)

    @workspace_data = fixture.workspace
    @earlier_handoffs = earlier_handoffs
    @usage_gaps ||= 0
    last_event_id = LlmEvent.where(account_id: account.id).maximum(:id).to_i
    judged = judge_turn(account, dialogue, turn, response, scored, history, tool_calls)
    [judged, provider_cost(LlmEvent.where(account_id: account.id).where('id > ?', last_event_id).order(:id).to_a)]
  end

  private

  def execute_fixture(path, fixture, run_index)
    fixture.dialogues.each do |dialogue|
      raise BudgetExceeded, 'budget_reached' if @spent >= @budget_usd

      execute_dialogue(path, fixture, dialogue, run_index)
    end
  end

  # Every dialogue gets its own synthetic workspace (account, agents, contacts, calendar seeds) inside its own
  # savepoint, which is always rolled back, so a booking moved or cancelled by one dialogue never reaches the next.
  # The savepoint is opened and rolled back explicitly: a block transaction holds the connection lock for its whole
  # duration, which deadlocks council threads that share the pinned benchmark connection (the rake task also runs the council
  # with CAPTAIN_COUNCIL_PARALLEL=off).
  def execute_dialogue(path, fixture, dialogue, run_index)
    @workspace_data = fixture.workspace
    connection = ActiveRecord::Base.connection
    connection.begin_transaction(joinable: false, _lazy: false)
    first_case = @cases.size
    begin
      workspace = Current.with_runtime_events_suppressed do
        Captain::Evals::RoutingBenchmark::Workspace.new(fixture, model: @model, reasoning: @reasoning).create!
      end
      run_dialogue(workspace, dialogue, path: path, run_index: run_index)
    ensure
      connection.rollback_transaction
      report_progress(dialogue, @cases[first_case..])
    end
  end

  # One line per dialogue, so a long run can be followed while it goes (it is flushed at once, whatever the buffering of the output):
  # "[3/395] council_two_part_04 turns passed 2/3, not evaluated 0, critical 1, hints 2 (critical 1), reasons: missing_operation:appointment,
  # wrong_agent". A dialogue that the budget or an error cut short reports the turns it played.
  def report_progress(dialogue, cases)
    @dialogues_done += 1
    return unless @progress

    reasons = cases.flat_map { |item| item[:reasons].to_a }.uniq.join(', ').truncate(REASONS_LIMIT)
    critical = cases.sum { |item| item[:failures].to_a.count { |failure| failure[:severity] == 'critical' } }
    hints = cases.flat_map { |item| item[:hints].to_a }
    @progress.puts("[#{@dialogues_done}/#{@dialogues_total}] #{dialogue.fetch('id')} turns passed #{cases.count { |item| item[:status] == 'pass' }}/" \
                   "#{cases.size}, not evaluated #{cases.count { |item| item[:status] == 'not_evaluated' }}, critical #{critical}, " \
                   "hints #{hints.size} (critical #{hints.count { |hint| hint[:severity] == 'critical' }}), reasons: #{reasons.presence || 'none'}")
    @progress.flush
  end

  def run_dialogue(workspace, dialogue, path:, run_index:)
    conversation = Current.with_runtime_events_suppressed { workspace.conversation_for(dialogue) }
    verify_silent_handoff(workspace, dialogue, conversation)
    history = []
    scorer = Captain::Evals::RoutingBenchmark::Scorer.new(
      account: workspace.account, conversation: conversation, directory: workspace.directory,
      internal_texts: workspace.agents.values.flat_map { |agent| [agent.description, agent.routing_description] }.compact
    )
    clock = Time.current
    @earlier_handoffs = 0
    dialogue.fetch('turns').each_with_index do |turn, index|
      raise BudgetExceeded, 'budget_reached' if @spent >= @budget_usd

      clock = Time.iso8601(turn['at']) if turn['at']
      clock += turn.fetch('delay_seconds', 0).to_f
      travel_to(clock) do
        apply_staff_intervention(conversation, turn['staff']) if turn['staff']
        scored = run_turn(workspace, dialogue, turn, conversation, history, scorer)
        @cases << scored.merge(fixture: path, dialogue: dialogue.fetch('id'), run: run_index, turn: index + 1)
        @earlier_handoffs += 1 if scored.dig(:handoff, :observed)
        raise BudgetExceeded, 'budget_reached' if @spent >= @budget_usd
      end
    end
  end

  # The handoff of the benchmark is silent: the text checks are not put to a handoff turn, so the account's handoff notice must be
  # blank, or a patient would read a sentence that nothing checked. The notice is asked for the way the response builder asks
  # without a model call (generate: false); it is checked once per run, on the first conversation.
  def verify_silent_handoff(workspace, dialogue, conversation)
    return unless @silent_handoff.nil?

    notice = Captain::CustomerNoticeService.new(conversation: conversation, assistant: workspace.entry_agent(dialogue), kind: :handoff, generate: false)
    @silent_handoff = notice.text.nil?
  rescue StandardError => e
    @silent_handoff_error = e.class.name
  end

  # One customer turn: the snapshots before it, the agent run, then the scoring of everything the turn did. The events
  # and tool audit rows of the whole turn are read, not only those of the request id the run returned: work that a
  # plan hands to another agent can run under another request id inside the same turn.
  def run_turn(workspace, dialogue, turn, conversation, history, scorer)
    account = workspace.account
    entry = workspace.entry_agent(dialogue)
    staff_owned = conversation.reload.status.to_s == 'open'
    before = record_snapshot(account)
    before_state = record_state(account)
    routing_before = routing_state(conversation, entry)
    last_event_id = LlmEvent.where(account_id: account.id).maximum(:id).to_i
    audit_cursor = Captain::Evals::RoutingBenchmark::ToolTrace.cursor(account)
    incoming = create_incoming!(conversation, turn.fetch('customer'))
    history << { role: 'user', content: incoming.content }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = Captain::Assistant::AgentRunnerService.new(
      assistant: entry, conversation: conversation, source: 'benchmark'
    ).generate_response(message_history: history)
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    events = LlmEvent.where(account_id: account.id).where('id > ?', last_event_id).order(:id).to_a
    tool_calls = Captain::Evals::RoutingBenchmark::ToolTrace.build(
      events: events, audits: Captain::Evals::RoutingBenchmark::ToolTrace.audits_after(account, audit_cursor), agent_names: agent_names(workspace)
    )
    routing = { before: routing_before, after: routing_state(conversation, entry) }
    scored = scorer.call(turn: turn, response: response, events: events, before: before, before_state: before_state, tool_calls: tool_calls,
                         routing: routing)
    scored = judge_turn(account, dialogue, turn, response, scored, history, tool_calls) if judge_turn?(dialogue, turn, scored)
    # The cost is read after the judge ran: its calls are provider spend of this turn too, and the next turn starts its own
    # window after the newest event, so a call left out here would never be counted against the budget.
    cost = provider_cost(LlmEvent.where(account_id: account.id).where('id > ?', last_event_id).order(:id).to_a)
    @spent += cost
    after_turn(entry, conversation, history, response, scored)
    scored = scored.merge(warnings: Array(scored[:warnings]) + (staff_owned && !turn['staff'] ? [STAFF_OWNED_WARNING] : []))
    scored = scored.merge(blocked: true) if staff_owned && !turn['staff']
    scored.merge(latency_ms: latency_ms, cost_usd: cost.to_f, expectation: turn['expect'],
                 **turn_trace(turn, response, events, tool_calls))
  end

  # What the response builder does after a reply: the history of the model, the delivery of the parts, the handoff.
  def after_turn(entry, conversation, history, response, scored)
    text = public_reply(response, scored)
    if text
      history << { role: 'assistant', content: text, agent_name: response['agent_name'] }
      record_part_delivery(entry, conversation, response, text)
    end
    hand_over(conversation) if staff_owned_after?(response, scored)
  end

  # ResponseBuilderJob leaves the conversation open (bot_handoff!) after the handoff tool, after the council handoff of an unresolved
  # part, and after a failed turn: the provider error response, a technical failure of a tool, and the technical handoff of a council part.
  def staff_owned_after?(response, scored)
    scored.dig(:handoff, :observed) || response['council_handoff'].present? || response['technical_failure'].present? ||
      response['response'] == Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE
  end

  # The reply the customer read, or nil: a runtime marker, a provider error, a suppressed reply and a technical failure show nothing.
  def public_reply(response, scored)
    return if scored[:patient_text].blank? || response['response_mode'] == 'suppress' || response['technical_failure'].present?

    response['response'].to_s
  end

  # ResponseBuilderJob#record_part_delivery: the reply is a delivery of every part it reports, of the version it reported.
  def record_part_delivery(entry, conversation, response, text)
    refs = Array(response['part_refs'])
    return if refs.empty?

    @delivery_sequence = @delivery_sequence.to_i + 1
    delivery_id = -@delivery_sequence
    Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation).change do |data|
      refs.each do |ref|
        part = Array(data['parts']).find { |item| item['id'] == ref['id'] && item['version'].to_i == ref['version'].to_i }
        next unless part

        part['delivered'] ||= []
        part['delivered'] << { 'message_id' => delivery_id, 'content' => text, 'at' => Time.current.iso8601, 'version' => part['version'].to_i }
      end
    end
  end

  # Conversation#bot_handoff! leaves the conversation open for staff.
  def hand_over(conversation)
    Current.with_runtime_events_suppressed { conversation.update!(status: :open) }
  end

  # The agent that holds the conversation and how often the routing changed, from the durable session of the conversation.
  def routing_state(conversation, entry)
    session = conversation.reload.additional_attributes.to_h['captain_agent_session'].to_h
    { current_assistant_id: session['current_assistant_id'] || entry.id, routing_revision: session['routing_revision'].to_i }
  end

  def agent_names(workspace) = workspace.agents.values.to_h { |agent| [agent.id, agent.name] }

  # Synthetic dialogue text only (no real customer data), kept for prompt review and for the triage list.
  def turn_trace(turn, response, events, tool_calls)
    completions = events.count { |event| event.event_name == 'llm.chat.runtime_complete' }
    completions = events.count { |event| event.event_name == 'llm.chat.request' } if completions.zero?
    tool_steps = events.select { |event| event.event_name == 'llm.tool.complete' }.map do |event|
      [event.tool_name, event.payload['result_success'], event.payload['duration_ms']].join(':')
    end
    { customer: turn['customer'].to_s, reply: response['response'].to_s.truncate(REPLY_LIMIT), llm_calls: completions,
      tool_steps: tool_steps, tool_calls: Captain::Evals::RoutingBenchmark::ToolTrace.compact(tool_calls),
      event_names: events.map(&:event_name).tally, response_keys: response.keys.sort, response_flags: response_flags(response) }
  end

  # What the runtime said about the turn besides the text: the language it decided on, the handoff, the response mode, the failure
  # and the plan.
  def response_flags(response)
    {
      patient_language: response['patient_language'].presence, response_mode: response['response_mode'],
      handoff_tool_called: response['handoff_tool_called'],
      handoff_reason: response['handoff_reason'], handoff_message: response['handoff_message'],
      council_handoff: response['council_handoff'].present? || nil, error_class: response['error_class'],
      error_message: response['error_message']&.truncate(300), part_refs: response['part_refs'].presence,
      technical_failure: response['technical_failure'].presence&.to_h&.slice('tool', 'stage', 'reason', 'kind', 'completed'),
      tool_result_fallback: response['tool_result_fallback'] || nil,
      agent_tasks: Array(response['agent_tasks']).filter_map { |task| task.to_h.stringify_keys.slice('id', 'status', 'assistant_id').presence }.presence
    }.compact
  end

  def create_incoming!(conversation, content)
    Message.create!(account: conversation.account, inbox: conversation.inbox, conversation: conversation,
                    sender: conversation.contact, message_type: :incoming, content: content,
                    skip_send_reply: true, skip_runtime_events: true)
  end

  def apply_staff_intervention(conversation, intervention)
    status = intervention.fetch('status')
    raise ArgumentError, 'Staff intervention status must be open or pending' unless %w[open pending].include?(status)

    Current.with_runtime_events_suppressed { conversation.update!(status: status) }
  end

  def record_snapshot(account)
    Captain::Evals::RoutingBenchmark::Scorer::OPERATION_MODELS.transform_values do |model|
      model.where(account_id: account.id).pluck(:id, :updated_at).to_h
    end
  end

  # The previous resource, service, start and status of every appointment, to compare a move with the old appointment.
  def record_state(account)
    rows = Scheduling::Appointment.where(account_id: account.id).pluck(:id, :resource_id, :service_id, :starts_at, :status)
    states = rows.to_h do |id, resource_id, service_id, starts_at, status|
      [id, { 'resource_id' => resource_id, 'service_id' => service_id, 'starts_at' => starts_at, 'status' => status }]
    end
    { 'appointment' => states }
  end

  def provider_cost(events)
    completions = events.select do |event|
      event.event_name == 'llm.chat.complete' && event.payload['usage_scope'] == 'provider_response'
    end
    raise BudgetExceeded, 'unexpected_chat_model' if completions.any? { |event| event.model != @model }
    requested = events.any? { |event| event.event_name == 'llm.chat.request' }
    if requested && completions.empty?
      @usage_gaps += 1
      raise BudgetExceeded, 'provider_usage_unavailable' if @usage_gaps > MAX_USAGE_GAPS
    end
    raise BudgetExceeded, 'provider_usage_unavailable' if completions.any? { |event| event.estimated_cost.nil? }

    completions.sum { |event| event.estimated_cost || BigDecimal('0') }
  end

  # The optional judge rates the reply against the rubric of the turn: what it must say and must not say, the tone and the language.
  # It sees the transcript so far, the tool calls with their owners and the database changes of the turn and the facts of the
  # workspace, but it can only add a failure: bookings, claims, handoffs and leaks are decided by the deterministic checks, never by
  # the judge, and a pass of the judge removes no failure. A turn with nothing to read (a silent handoff, a runtime marker) is not
  # judged.
  def judge_turn?(dialogue, turn, scored)
    @judge && (turn['rubric'].present? || dialogue['rubric'].present?) && scored[:patient_text].present?
  end

  # The judge is the arbiter of the text of the reply (the checks that read text only give it hints, see Scorer). A turn that is judged
  # and gets no verdict is NOT_EVALUATED: not a pass, not a failure (see #judge_unusable).
  def judge_turn(account, dialogue, turn, response, scored, history, tool_calls)
    prompt = judge_prompt(dialogue, turn, response, scored, history, tool_calls)
    result, finish_reason, attempts = ask_judge(account, prompt)
    verdict = { pass: result['pass'], reason: result['reason'].to_s.truncate(300), finish_reason: finish_reason,
                attempts: (attempts if attempts > 1) }.compact
    scored = scored.merge(judge: verdict)
    result['pass'] == true ? scored : Captain::Evals::RoutingBenchmark::Scorer.with_failure(scored, 'judge_failed', result['reason'].to_s.truncate(300))
  rescue UnusableVerdict => e
    detail = [("finish_reason #{e.finish_reason}" if e.finish_reason), e.message].compact.join(': ')
    judge_unusable(scored, 'judge_invalid_json', detail, finish_reason: e.finish_reason)
  rescue JSON::ParserError => e
    judge_unusable(scored, 'judge_invalid_json', e.message.to_s.squish.truncate(160))
  rescue StandardError => e
    judge_unusable(scored, 'judge_unavailable', error_detail(e))
  end

  # [the verdict of the judge ({'pass' => true|false, 'reason' => ...}), the finish_reason of the call, the number of calls]. A call that
  # fails (the provider, a limit, an answer that is no verdict) is asked again, at most JUDGE_RETRIES times; the error of the last
  # attempt is raised.
  def ask_judge(account, prompt)
    attempts = 0
    begin
      attempts += 1
      result, finish_reason = verdict_of(request_judge(account, prompt))
      [result, finish_reason, attempts]
    rescue StandardError
      raise if attempts > JUDGE_RETRIES

      judge_pause(JUDGE_PAUSE_SECONDS * attempts)
      retry
    end
  end

  def request_judge(account, prompt)
    Llm::EventBus.with_context(source: 'benchmark', feature: 'routing_benchmark', account_id: account.id) do
      Llm::Runtime.ask(judge_chat(account), prompt, model: @model, account: account,
                                                    observability: { feature: 'routing_benchmark', source: 'benchmark', account_id: account.id })
    end
  end

  # [the verdict, the finish_reason of the call]. An answer that is no verdict raises UnusableVerdict with the finish_reason.
  def verdict_of(judgment)
    finish_reason = finish_reason_of(judgment)
    result = JSON.parse(json_text(judgment.content))
    raise UnusableVerdict.new('Judge response is not a verdict', finish_reason) unless result.is_a?(Hash) && [true, false].include?(result['pass'])

    [result, finish_reason]
  rescue UnusableVerdict
    raise
  rescue JSON::ParserError => e
    raise UnusableVerdict.new(e.message.to_s.squish.truncate(80), finish_reason)
  end

  # Why the provider ended the answer (`stop`, `length` ...), from the raw response of the call; nil when the response keeps none.
  def finish_reason_of(judgment)
    body = judgment.respond_to?(:raw) ? judgment.raw&.body : nil
    body = JSON.parse(body) if body.is_a?(String)
    body.is_a?(Hash) ? body.dig('choices', 0, 'finish_reason').to_s.presence : nil
  rescue StandardError
    nil
  end

  def judge_pause(seconds) = sleep(seconds)

  # The class of the error and the start of its message, without anything that looks like a key: enough to tell a rate limit from a
  # too long input or a schema problem in the report.
  def error_detail(error)
    message = error.message.to_s.gsub(/\b(?:sk|or|key)[-_][A-Za-z0-9_-]{8,}/i, '[key]').gsub(/Bearer\s+\S+/i, 'Bearer [key]').squish
    [error.class.name, message.truncate(160)].reject(&:blank?).join(': ')
  end

  # A judge that could not be called or whose answer could not be read says nothing about the reply, and nothing else reads the text of
  # the reply: the required check of the turn has no verdict, so the turn is NOT_EVALUATED. It is not a pass and not a failure (a turn
  # that fails a fact check stays failed). The turn carries the cause as a warning and in `judge`, and the summary counts these turns
  # apart; the gate reports INCOMPLETE_EVALUATION while any turn is left so. The rake task captain:routing_benchmark_rejudge asks again
  # for the turns that carry it.
  def judge_unusable(scored, reason, detail = nil, finish_reason: nil)
    scored.merge(judge: { unusable: reason, detail: detail, finish_reason: finish_reason }.compact, warnings: Array(scored[:warnings]) + [reason],
                 not_evaluated: [NOT_EVALUATED_JUDGE], status: scored[:status] == 'pass' ? 'not_evaluated' : scored[:status])
  end

  # The judge is a plain text completion on the benchmark model, built the way every feature of the runtime builds its chat: with a
  # feature (captain_agent, like the council editor: text in, text out, no tools; see JUDGE_FEATURE for why not the editor feature), so
  # the account's own key and routing apply, and with the benchmark model first: a model that answers in its place is reported by the
  # budget check (unexpected_chat_model), as for the agents.
  # An earlier call carried no feature and no `options`, took the runtime's legacy path and raised TypeError (nil into
  # Hash#merge!) before any request left: every judged turn became judge_unavailable.
  # The parameters of the model decide what a request may carry: a model that thinks takes no temperature. The limit of the output is
  # set (JUDGE_MAX_TOKENS) because the judge thinks.
  def judge_chat(account)
    parameters = Llm::ModelParameters.for(@model, account: account).compile(temperature: 0, thinking: { effort: JUDGE_THINKING_EFFORT })
    Llm::Runtime.build_chat(feature: JUDGE_FEATURE, account: account, model: @model, models: [@model],
                            options: parameters.merge(max_tokens: JUDGE_MAX_TOKENS))
  end

  # The verdict, whether or not the model wrapped it in a ```json fence.
  def json_text(content)
    content.to_s.strip.sub(/\A```(?:json)?\s*/i, '').sub(/\s*```\z/, '').strip
  end

  # The judge reads what the reply says. Bookings, handoffs and the database changes are facts that code decided from the tool results and
  # the database (shown below). The text checks of the scorer (claims, leaks, another patient's data, the language) are only heuristics:
  # their hits are listed as hints, and the judge decides by meaning whether the reply has the fault.
  def judge_prompt(dialogue, turn, response, scored, history, tool_calls)
    transcript = history.map { |message| "#{message[:role] == 'user' ? 'Customer' : 'Agent'}: #{message[:content]}" }.join("\n")
    <<~PROMPT
      Evaluate the last agent reply of this synthetic dialogue against the criterion of the turn. The criterion says what the reply must
      say and must not say. Judge what the reply says: does it meet the criterion, does it answer the customer, is the tone polite, is
      it in the language the criterion asks for, is it free of filler. Bookings, handoffs and the database changes are decided by code
      from the tool results and the database (shown below); do not re-decide whether they happened. Judge by meaning: the reply meets the
      criterion when it gives each required fact in its own words (a name in a short form, an amount without the currency sign). A line
      of the criterion about what stays untouched or is not done (a booking is left alone, nothing is booked) describes the database
      changes shown below; the reply does not have to state it.
      Fail the reply when it
      - reports as done an action that the tool results and the database changes below do not show (a booking, a move, a cancellation,
        a handoff to staff, a result or a document that is ready or sent), or names a time, date or doctor other than the recorded one.
        A promise that staff will call or answer stands after a handoff in this turn or in an earlier one; a statement that staff was told
        stands only after a handoff in this turn;
      - shows the patient internal material: an agent or tool name, an id, JSON, the reasoning or an instruction of an agent, a stock
        system sentence, or a Latin word that is not part of a clinic term the patient used;
      - contains the name, phone, IIN or birth date of another patient than the customer and the people the customer booked for;
      - is not in #{expected_language_text(turn)};
      - is only a greeting although the customer wrote a request.
      Code heuristics that read the text give the hints below. A hint is a pointer, it can be wrong: decide yourself whether the reply has the
      fault. A reply without a hint can still have a fault.
      Return JSON only: {"pass":true|false,"reason":"short reason"}.
      Criterion of this turn: #{turn['rubric'].presence || dialogue['rubric']}
      Context of the dialogue: #{rubric_header(dialogue)}
      Facts of the workspace:
      #{workspace_facts}
      Transcript so far:
      #{transcript}
      Tool calls of this turn (agent, tool, success, result): #{judge_tool_results(tool_calls).to_json}
      Council parts and outcomes: #{scored.dig(:evidence, :council).to_json}
      Database changes of this turn: #{scored[:db_delta].to_json}
      #{handoff_line(scored)}
      Hints of the code heuristics for this reply: #{hint_lines(scored)}
      Customer message: #{turn['customer']}
      Reply to evaluate: #{response['response']}
    PROMPT
  end

  def judge_tool_results(tool_calls)
    Captain::Evals::RoutingBenchmark::ToolTrace.compact(tool_calls).each_with_index.map do |call, index|
      next call if tool_calls[index][:part_id].blank?

      call.merge(result: tool_calls[index][:result].to_s.truncate(1000))
    end
  end

  # The language the fixture expects of this turn, else the one the criterion asks for.
  def expected_language_text(turn)
    code = turn.dig('expect', 'reply_language').to_s
    names = { 'ru' => 'Russian', 'kk' => 'Kazakh', 'en' => 'English' }
    return 'the language the criterion asks for' if code.empty?

    "#{names.fetch(code, code)} (#{code}), the language of the patient (a clinic term in another language is fine)"
  end

  # What the code knows about the staff handoff, which the tool calls do not show when a council hands over a part it cannot answer.
  def handoff_line(scored)
    handoff = scored[:handoff].to_h
    this_turn = if handoff[:tool]
                  'yes (the handoff tool)'
                elsif handoff[:observed]
                  'yes (the council hands a part it cannot answer to staff)'
                else
                  'no'
                end
    "Handed to staff in this turn: #{this_turn}. Handed to staff in earlier turns of this dialogue: #{@earlier_handoffs.to_i} time(s)."
  end

  def hint_lines(scored)
    hints = Array(scored[:hints])
    return 'none' if hints.empty?

    hints.map { |hint| "#{hint[:id]}#{": #{hint[:detail].to_s.squish.truncate(200)}" if hint[:detail].present?}" }.join(' | ')
  end

  # The dialogue rubric up to the first "Ход 1:": who the patient is and the rules for all replies.
  def rubric_header(dialogue)
    dialogue['rubric'].to_s.split(/\s*Ход\s+1:/, 2).first.to_s.squish
  end

  # Prices, doctors, and the knowledge base of the workspace: what a correct reply may state.
  def workspace_facts
    data = @workspace_data || {}
    lines = []
    lines << "Doctors: #{data.fetch('resources', []).pluck('name').join('; ')}"
    lines << "Services: #{data.fetch('services', []).map { |row| "#{row['name']} #{row['base_price']} KZT, #{row['duration_min']} min" }.join('; ')}"
    data.fetch('knowledge', []).each { |row| lines << "Q: #{row['question']} A: #{row['answer']}" }
    lines.join("\n").truncate(FACTS_LIMIT)
  end

  def build_report(labels)
    cases = @cases.map { |item| item.deep_stringify_keys }
    summary = Captain::Evals::RoutingBenchmark::Summary.call(cases)
    gate = Captain::Evals::RoutingBenchmark::Gate.call(cases, aborted: @aborted, abort_reason: @abort_reason, labels: labels,
                                                              silent_handoff: @silent_handoff, silent_handoff_error: @silent_handoff_error,
                                                              judge: @judge)
    {
      gate: gate,
      triage: Captain::Evals::RoutingBenchmark::Triage.records(cases, labels: labels),
      needs_review: Captain::Evals::RoutingBenchmark::Review.records(cases),
      model: @model, reasoning: @reasoning, judge: @judge, runs: @runs, aborted: @aborted, abort_reason: @abort_reason,
      aborted_at_budget: @abort_reason == 'budget_reached', isolation: 'workspace_per_dialogue',
      budget_usd: @budget_usd.to_f, cost_usd: @spent.to_f,
      silent_handoff: @silent_handoff, silent_handoff_error: @silent_handoff_error,
      warnings: council_warnings + case_warnings + handoff_warnings,
      cases: @cases,
      aggregates: aggregates(summary),
      dialogue_summaries: summary[:dialogue_summaries]
    }.compact
  end

  def aggregates(summary)
    latencies = @cases.pluck(:latency_ms).sort
    total = @cases.size
    {
      total: total, passed: @cases.count { |item| item[:status] == 'pass' },
      # Turns the judge gave no verdict for (see #judge_unusable): neither passed nor failed.
      not_evaluated: @cases.count { |item| item[:status] == 'not_evaluated' },
      # Turns that pass once the council signal is ignored: separates a silent council producer from real failures.
      passed_ignoring_council_signal: @cases.count { |item| item[:status] != 'not_evaluated' && (item[:reasons] - council_reasons).empty? },
      council_detection: ratio(@cases.count { |item| (item[:reasons] & council_reasons).empty? }, total),
      council_expected: @cases.count { |item| item[:council_expected] == true },
      council_event_missing: count_reason('council_event_missing'),
      council_unexpected: count_reason('council_unexpected'),
      hard_zero: @cases.flat_map { |item| item[:hard_zero].to_a }.group_by(&:first).transform_values { |pairs| pairs.sum(&:last) },
      latency_p50_ms: percentile(latencies, 0.5), latency_p95_ms: percentile(latencies, 0.95)
    }.merge(summary.except(:dialogue_summaries)).compact
  end

  def council_reasons = Captain::Evals::RoutingBenchmark::Scorer::COUNCIL_REASONS

  def count_reason(reason)
    @cases.count { |item| item[:reasons].include?(reason) }
  end

  # A silent council producer would make every council turn fail with council_event_missing; say so explicitly.
  def council_warnings
    missing = count_reason('council_event_missing')
    return [] if missing.zero?

    expected = @cases.count { |item| item[:council_expected] == true }
    signal = Captain::Evals::RoutingBenchmark::Scorer::COUNCIL_STARTED
    ["council_event_missing: #{missing} of #{expected} turns expecting a council saw no #{signal} event; " \
     'check that the runtime emits it before reading the routing results']
  end

  # The warnings of the turns, counted: "ai_answered_while_staff_owned: 3 turn(s)".
  def case_warnings
    @cases.flat_map { |item| Array(item[:warnings]).uniq }.tally.sort.map { |warning, count| "#{warning}: #{count} turn(s)" }
  end

  def handoff_warnings
    return ["the handoff notice could not be checked (#{@silent_handoff_error}): silent handoff is not proven"] if @silent_handoff.nil? && @silent_handoff_error

    @silent_handoff == false ? ['the handoff notice of the synthetic account is not blank: a handoff is not silent'] : []
  end

  def ratio(count, total)
    total.zero? ? 0.0 : (count.to_f / total).round(4)
  end

  def percentile(values, fraction)
    return if values.empty?

    values[[(values.length * fraction).ceil - 1, 0].max]
  end

  def write_report(report)
    File.open(@out, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.pretty_generate(report)) }
    File.open("#{@out}.md", File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(Captain::Evals::RoutingBenchmark::Report.new(report).markdown)
    end
  end
end
