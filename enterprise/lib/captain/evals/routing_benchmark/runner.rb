# frozen_string_literal: true

require 'active_support/testing/time_helpers'

require 'json'

class Captain::Evals::RoutingBenchmark::Runner
  include ActiveSupport::Testing::TimeHelpers

  MODEL = 'openai/gpt-6-luna'
  class BudgetExceeded < StandardError; end

  # A turn whose request left no provider usage row (a failed or aborted call) is counted; several such turns stop
  # the run, because the budget can no longer be trusted.
  MAX_USAGE_GAPS = 3
  REPLY_LIMIT = 4000

  # triage: path of an earlier report (or label file) whose triage records a person filled in; see Triage.load.
  def initialize(fixtures:, runs: 3, model: MODEL, reasoning: 'none', budget_usd:, out:, judge: false, triage: nil)
    @fixtures, @runs, @model, @reasoning = fixtures, Integer(runs), model, reasoning
    @budget_usd, @out, @judge = BigDecimal(budget_usd.to_s), out, judge
    @triage = triage
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
    connection = ActiveRecord::Base.connection
    connection.begin_transaction(joinable: false, _lazy: false)
    begin
      workspace = Current.with_runtime_events_suppressed do
        Captain::Evals::RoutingBenchmark::Workspace.new(fixture, model: @model, reasoning: @reasoning).create!
      end
      run_dialogue(workspace, dialogue, path: path, run_index: run_index)
    ensure
      connection.rollback_transaction
    end
  end

  def run_dialogue(workspace, dialogue, path:, run_index:)
    conversation = Current.with_runtime_events_suppressed { workspace.conversation_for(dialogue) }
    history = []
    scorer = Captain::Evals::RoutingBenchmark::Scorer.new(
      account: workspace.account, conversation: conversation, directory: workspace.directory,
      internal_texts: workspace.agents.values.flat_map { |agent| [agent.description, agent.routing_description] }.compact
    )
    clock = Time.current
    dialogue.fetch('turns').each_with_index do |turn, index|
      raise BudgetExceeded, 'budget_reached' if @spent >= @budget_usd

      clock = Time.iso8601(turn['at']) if turn['at']
      clock += turn.fetch('delay_seconds', 0).to_f
      travel_to(clock) do
        apply_staff_intervention(conversation, turn['staff']) if turn['staff']
        scored = run_turn(workspace, dialogue, turn, conversation, history, scorer)
        @cases << scored.merge(fixture: path, dialogue: dialogue.fetch('id'), run: run_index, turn: index + 1)
        raise BudgetExceeded, 'budget_reached' if @spent >= @budget_usd
      end
    end
  end

  # One customer turn: the snapshots before it, the agent run, then the scoring of everything the turn did. The events
  # and tool audit rows of the whole turn are read, not only those of the request id the run returned: work that a
  # plan hands to another agent can run under another request id inside the same turn.
  def run_turn(workspace, dialogue, turn, conversation, history, scorer)
    account = workspace.account
    before = record_snapshot(account)
    before_state = record_state(account)
    last_event_id = LlmEvent.where(account_id: account.id).maximum(:id).to_i
    audit_cursor = Captain::Evals::RoutingBenchmark::ToolTrace.cursor(account)
    incoming = create_incoming!(conversation, turn.fetch('customer'))
    history << { role: 'user', content: incoming.content }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = Captain::Assistant::AgentRunnerService.new(
      assistant: workspace.entry_agent(dialogue), conversation: conversation, source: 'benchmark'
    ).generate_response(message_history: history)
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    events = LlmEvent.where(account_id: account.id).where('id > ?', last_event_id).order(:id).to_a
    tool_calls = Captain::Evals::RoutingBenchmark::ToolTrace.build(
      events: events, audits: Captain::Evals::RoutingBenchmark::ToolTrace.audits_after(account, audit_cursor)
    )
    scored = scorer.call(turn: turn, response: response, events: events, before: before, before_state: before_state, tool_calls: tool_calls)
    scored = judge_turn(account, dialogue, turn, response, scored, history, tool_calls) if @judge && dialogue['rubric'].present?
    cost = provider_cost(events)
    @spent += cost
    history << { role: 'assistant', content: response['response'].to_s, agent_name: response['agent_name'] }
    scored.merge(latency_ms: latency_ms, cost_usd: cost.to_f, expectation: turn['expect'],
                 **turn_trace(turn, response, events, tool_calls))
  end

  # Synthetic dialogue text only (no real customer data), kept for prompt review and for the triage list.
  def turn_trace(turn, response, events, tool_calls)
    completions = events.count { |event| event.event_name == 'llm.chat.runtime_complete' }
    completions = events.count { |event| event.event_name.to_s.end_with?('chat.complete') } if completions.zero?
    tool_steps = events.select { |event| event.event_name == 'llm.tool.complete' }.map do |event|
      [event.tool_name, event.payload['result_success'], event.payload['duration_ms']].join(':')
    end
    { customer: turn['customer'].to_s, reply: response['response'].to_s.truncate(REPLY_LIMIT), llm_calls: completions,
      tool_steps: tool_steps, tool_calls: Captain::Evals::RoutingBenchmark::ToolTrace.compact(tool_calls),
      event_names: events.map(&:event_name).tally, response_keys: response.keys.sort, response_flags: response_flags(response) }
  end

  # What the runtime said about the turn besides the text: the handoff, the response mode, the failure and the plan.
  def response_flags(response)
    {
      response_mode: response['response_mode'], handoff_tool_called: response['handoff_tool_called'],
      handoff_reason: response['handoff_reason'], handoff_message: response['handoff_message'],
      council_handoff: response['council_handoff'].present? || nil, error_class: response['error_class'],
      error_message: response['error_message']&.truncate(300), part_refs: response['part_refs'].presence,
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

  # The optional judge rates the quality of the reply only (does it answer, tone, language). It sees the transcript so
  # far, the tool calls and the database changes of the turn, but it can only add a failure: bookings, claims, handoffs
  # and leaks are decided by the deterministic checks, never by the judge.
  def judge_turn(account, dialogue, turn, response, scored, history, tool_calls)
    prompt = judge_prompt(dialogue, turn, response, scored, history, tool_calls)
    judgment = Llm::EventBus.with_context(source: 'benchmark', feature: 'routing_benchmark', account_id: account.id) do
      chat = Llm::Runtime.build_chat(model: @model, account: account)
      Llm::Runtime.ask(chat, prompt, model: @model, account: account,
                                     observability: { feature: 'routing_benchmark', source: 'benchmark', account_id: account.id })
    end
    result = JSON.parse(judgment.content.to_s)
    raise JSON::ParserError, 'Judge response is not a verdict' unless result.is_a?(Hash) && [true, false].include?(result['pass'])

    scored = scored.merge(judge: { pass: result['pass'], reason: result['reason'].to_s.truncate(300) })
    result['pass'] == true ? scored : Captain::Evals::RoutingBenchmark::Scorer.with_failure(scored, 'judge_failed', result['reason'].to_s.truncate(300))
  rescue JSON::ParserError
    Captain::Evals::RoutingBenchmark::Scorer.with_failure(scored, 'judge_invalid_json')
  rescue StandardError => e
    Captain::Evals::RoutingBenchmark::Scorer.with_failure(scored, 'judge_unavailable', e.class.name)
  end

  def judge_prompt(dialogue, turn, response, scored, history, tool_calls)
    transcript = history.map { |message| "#{message[:role] == 'user' ? 'Customer' : 'Agent'}: #{message[:content]}" }.join("\n")
    <<~PROMPT
      Evaluate the quality of the last agent reply of this synthetic dialogue. Judge only: does it answer what the customer
      asked, is the tone polite, is it in the customer's language, is it free of filler. Do not judge bookings, handoffs or
      leaks: code checks them. Return JSON only: {"pass":true|false,"reason":"short reason"}.
      Dialogue rubric (context for the whole dialogue): #{dialogue['rubric']}
      Transcript so far:
      #{transcript}
      Tool calls of this turn: #{Captain::Evals::RoutingBenchmark::ToolTrace.compact(tool_calls).to_json}
      Database changes of this turn: #{scored[:db_delta].to_json}
      Customer message: #{turn['customer']}
      Reply to evaluate: #{response['response']}
    PROMPT
  end

  def build_report(labels)
    cases = @cases.map { |item| item.deep_stringify_keys }
    {
      gate: Captain::Evals::RoutingBenchmark::Gate.call(cases, aborted: @aborted, abort_reason: @abort_reason, labels: labels),
      triage: Captain::Evals::RoutingBenchmark::Triage.records(cases, labels: labels),
      model: @model, reasoning: @reasoning, runs: @runs, aborted: @aborted, abort_reason: @abort_reason,
      aborted_at_budget: @abort_reason == 'budget_reached', isolation: 'workspace_per_dialogue',
      budget_usd: @budget_usd.to_f, cost_usd: @spent.to_f,
      warnings: council_warnings,
      cases: @cases,
      aggregates: aggregates
    }
  end

  def aggregates
    latencies = @cases.pluck(:latency_ms).sort
    total = @cases.size
    {
      total: total, passed: @cases.count { |item| item[:status] == 'pass' },
      # Turns that pass once the council signal is ignored: separates a silent council producer from real failures.
      passed_ignoring_council_signal: @cases.count { |item| (item[:reasons] - council_reasons).empty? },
      routing_accuracy: ratio(@cases.count { |item| item[:reasons].exclude?('wrong_agent') }, total),
      council_detection: ratio(@cases.count { |item| (item[:reasons] & council_reasons).empty? }, total),
      council_expected: @cases.count { |item| item[:council_expected] },
      council_event_missing: count_reason('council_event_missing'),
      council_unexpected: count_reason('council_unexpected'),
      hard_zero: @cases.flat_map { |item| item[:hard_zero].to_a }.group_by(&:first).transform_values { |pairs| pairs.sum(&:last) },
      latency_p50_ms: percentile(latencies, 0.5), latency_p95_ms: percentile(latencies, 0.95)
    }
  end

  def council_reasons = Captain::Evals::RoutingBenchmark::Scorer::COUNCIL_REASONS

  def count_reason(reason)
    @cases.count { |item| item[:reasons].include?(reason) }
  end

  # A silent council producer would make every council turn fail with council_event_missing; say so explicitly.
  def council_warnings
    missing = count_reason('council_event_missing')
    return [] if missing.zero?

    expected = @cases.count { |item| item[:council_expected] }
    signal = Captain::Evals::RoutingBenchmark::Scorer::COUNCIL_STARTED
    ["council_event_missing: #{missing} of #{expected} turns expecting a council saw no #{signal} event; " \
     'check that the runtime emits it before reading the routing results']
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
