# frozen_string_literal: true

require 'json'

class Captain::Evals::RoutingBenchmark::Runner
  include ActiveSupport::Testing::TimeHelpers

  MODEL = 'openai/gpt-6-luna'
  class BudgetExceeded < StandardError; end

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
    ActiveRecord::Base.transaction(requires_new: true) do
      workspace = Current.with_runtime_events_suppressed do
        Captain::Evals::RoutingBenchmark::Workspace.new(fixture, model: @model, reasoning: @reasoning).create!
      end
      fixture.dialogues.each do |dialogue|
        raise BudgetExceeded, 'budget_reached' if @spent >= @budget_usd

        run_dialogue(workspace, dialogue, path: path, run_index: run_index)
      end
      raise ActiveRecord::Rollback
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
                               latency_ms: latency_ms, cost_usd: cost.to_f)
        raise BudgetExceeded, 'budget_reached' if @spent >= @budget_usd

        history << { role: 'assistant', content: response['response'].to_s, agent_name: response['agent_name'] }
      end
    end
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
    raise BudgetExceeded, 'provider_usage_unavailable' if requested && completions.empty?
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
    latencies = @cases.pluck(:latency_ms).sort
    total = @cases.size
    {
      model: @model, reasoning: @reasoning, runs: @runs, aborted: @aborted, abort_reason: @abort_reason,
      aborted_at_budget: @abort_reason == 'budget_reached',
      budget_usd: @budget_usd.to_f, cost_usd: @spent.to_f,
      cases: @cases,
      aggregates: {
        total: total, passed: @cases.count { |item| item[:status] == 'pass' },
        routing_accuracy: ratio(@cases.count { |item| item[:reasons].exclude?('wrong_agent') }, total),
        council_detection: ratio(@cases.count { |item| item[:reasons].exclude?('council_mismatch') }, total),
        hard_zero: @cases.flat_map { |item| item[:hard_zero].to_a }.group_by(&:first).transform_values { |pairs| pairs.sum(&:last) },
        latency_p50_ms: percentile(latencies, 0.5), latency_p95_ms: percentile(latencies, 0.95)
      }
    }
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
    summary = <<~MARKDOWN
      # Routing benchmark

      Model: #{@model}; runs: #{@runs}; cases: #{report.dig(:aggregates, :total)}; passed: #{report.dig(:aggregates, :passed)}.
      Routing accuracy: #{report.dig(:aggregates, :routing_accuracy)}; council detection: #{report.dig(:aggregates, :council_detection)}.
      Hard-zero counters: #{report.dig(:aggregates, :hard_zero).to_json}.
      Latency p50/p95: #{report.dig(:aggregates, :latency_p50_ms)}/#{report.dig(:aggregates, :latency_p95_ms)} ms.
      Estimated provider cost: $#{report[:cost_usd]}; budget reached: #{report[:aborted_at_budget]}.
    MARKDOWN
    File.open("#{@out}.md", File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(summary) }
  end
end
