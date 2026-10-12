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

  def initialize(fixtures:, runs: 3, model: MODEL, reasoning: 'none', budget_usd:, out:, judge: false)
    @fixtures, @runs, @model, @reasoning = fixtures, Integer(runs), model, reasoning
    @budget_usd, @out, @judge = BigDecimal(budget_usd.to_s), out, judge
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
    report = build_report
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
      account: workspace.account, conversation: conversation,
      internal_texts: workspace.agents.values.map(&:description)
    )
    clock = Time.current
    dialogue.fetch('turns').each_with_index do |turn, index|
      raise BudgetExceeded, 'budget_reached' if @spent >= @budget_usd

      clock = Time.iso8601(turn['at']) if turn['at']
      clock += turn.fetch('delay_seconds', 0).to_f
      travel_to(clock) do
        apply_staff_intervention(conversation, turn['staff']) if turn['staff']
        before = record_snapshot(workspace.account)
        last_event_id = LlmEvent.where(account_id: workspace.account.id).maximum(:id).to_i
        incoming = create_incoming!(conversation, turn.fetch('customer'))
        history << { role: 'user', content: incoming.content }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = Captain::Assistant::AgentRunnerService.new(
          assistant: workspace.entry_agent(dialogue), conversation: conversation, source: 'benchmark'
        ).generate_response(message_history: history)
        latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        request_id = response['captain_request_id']
        events = request_id ? LlmEvent.where(account_id: workspace.account.id, request_id: request_id).to_a : []
        scored = scorer.call(turn: turn, response: response, events: events, before: before)
        scored = judge_turn(workspace.account, dialogue, turn, response, scored) if @judge && dialogue['rubric'].present?
        cost = provider_cost(LlmEvent.where(account_id: workspace.account.id).where('id > ?', last_event_id).to_a)
        @spent += cost
        @cases << scored.merge(fixture: path, dialogue: dialogue.fetch('id'), run: run_index, turn: index + 1,
                               latency_ms: latency_ms, cost_usd: cost.to_f, **turn_trace(turn, response, events))
        raise BudgetExceeded, 'budget_reached' if @spent >= @budget_usd

        history << { role: 'assistant', content: response['response'].to_s, agent_name: response['agent_name'] }
      end
    end
  end

  # Synthetic dialogue text only (no real customer data), kept for prompt review.
  def turn_trace(turn, response, events)
    completions = events.count { |event| event.event_name.to_s.end_with?('chat.complete') }
    tool_steps = events.select { |event| event.event_name == 'llm.tool.complete' }.map do |event|
      [event.tool_name, event.payload['result_success'], event.payload['duration_ms']].join(':')
    end
    { customer: turn['customer'].to_s, reply: response['response'].to_s.truncate(1200), llm_calls: completions,
      tool_steps: tool_steps, event_names: events.map(&:event_name).tally, response_keys: response.keys.sort }
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

  def judge_turn(account, dialogue, turn, response, scored)
    prompt = <<~PROMPT
      Evaluate this synthetic assistant reply against the rubric. Return JSON only: {"pass":true|false,"reason":"short reason"}.
      Rubric: #{dialogue['rubric']}
      Customer: #{turn['customer']}
      Reply: #{response['response']}
    PROMPT
    judgment = Llm::EventBus.with_context(source: 'benchmark', feature: 'routing_benchmark', account_id: account.id) do
      chat = Llm::Runtime.build_chat(model: @model, account: account)
      Llm::Runtime.ask(chat, prompt, model: @model, account: account,
                       observability: { feature: 'routing_benchmark', source: 'benchmark', account_id: account.id })
    end
    result = JSON.parse(judgment.content.to_s)
    raise JSON::ParserError, 'Judge response is not a verdict' unless result.is_a?(Hash) && [true, false].include?(result['pass'])
    return scored if result['pass'] == true

    scored.merge(status: 'fail', reasons: scored[:reasons] + ['judge_failed'])
  rescue JSON::ParserError
    scored.merge(status: 'fail', reasons: scored[:reasons] + ['judge_invalid_json'])
  end

  def build_report
    {
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
    File.open("#{@out}.md", File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(summary_markdown(report)) }
  end

  def summary_markdown(report)
    agg = report[:aggregates]
    <<~MARKDOWN
      # Routing benchmark

      Model: #{@model}; runs: #{@runs}; cases: #{agg[:total]}; passed: #{agg[:passed]}.
      Routing accuracy: #{agg[:routing_accuracy]}; council detection: #{agg[:council_detection]}.
      Council turns: #{agg[:council_expected]}; event missing: #{agg[:council_event_missing]}; unexpected: #{agg[:council_unexpected]}.
      Passed when the council signal is ignored: #{agg[:passed_ignoring_council_signal]}.
      Hard-zero counters: #{agg[:hard_zero].to_json}.
      Latency p50/p95: #{agg[:latency_p50_ms]}/#{agg[:latency_p95_ms]} ms.
      Estimated provider cost: $#{report[:cost_usd]}; budget reached: #{report[:aborted_at_budget]}.
      #{report[:warnings].map { |warning| "WARNING: #{warning}" }.join("\n")}
    MARKDOWN
  end
end
