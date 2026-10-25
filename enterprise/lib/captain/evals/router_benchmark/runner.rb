# frozen_string_literal: true

# Runs the router benchmark live against OpenRouter: every scenario becomes the same RoutingSnapshot and the same criteria the live
# router builds. Two modes, one row each:
#   model     each model of MODELS answers the question alone (one call, no chain, no escalation): raw accuracy and confidence
#   pipeline  the production decision (Captain::Runtime::DecisionRouter: the platform chain, the thresholds, the bounce guard and,
#             with ESCALATION=1, the escalation model)
# The cost of every call is read from the recorded llm events of the benchmark account; the run stops at the budget.
class Captain::Evals::RouterBenchmark::Runner
  class BudgetExceeded < StandardError; end

  Row = Struct.new(:suite, :scenario_id, :run, :mode, :model, :expected, :got, :confidence, :escalated, :escalation_trigger,
                   :first_choice, :decided_by, :chain_position, :latency_ms, :cost_usd, :error, keyword_init: true)

  # fixture: Captain::Evals::RouterBenchmark::Fixture; account: the (throwaway) account the calls are made for; models: the models
  # called alone; chain: run the production pipeline; escalation: let the pipeline call the escalation model.
  def initialize(fixture:, account:, options: {})
    @fixture = fixture
    @account = account
    @models = Array(options[:models])
    @chain = options.fetch(:chain, true)
    @escalation = options.fetch(:escalation, true)
    @runs = [options.fetch(:runs, 1).to_i, 1].max
    @budget = BigDecimal(options.fetch(:budget_usd, 1).to_s)
    @progress = options[:progress]
    @spent = BigDecimal(0)
    @rows = []
  end

  attr_reader :rows, :spent

  def call
    total = @fixture.scenario_count * @runs
    index = 0
    (1..@runs).each do |run|
      @fixture.suites.each do |suite|
        suite.scenarios.each do |scenario|
          index += 1
          play(suite, scenario, run, "#{index}/#{total}")
        end
      end
    end
    @rows
  rescue BudgetExceeded
    @rows
  end

  private

  def play(suite, scenario, run, position)
    snapshot = Captain::Runtime::RoutingSnapshot.from_fixture(candidates: suite.candidates, scenario: scenario, clinic: suite.clinic)
    @models.each { |model| record(position, measure { model_row(suite, scenario, run, snapshot, model) }) }
    record(position, measure { pipeline_row(suite, scenario, run, snapshot) }) if @chain
  end

  # One model alone, the same questions and composition as the production router, no escalation: raw accuracy and confidence.
  # Answers that contradict each other come back as "inconsistent".
  def model_row(suite, scenario, run, snapshot, model)
    decision = Captain::Runtime::DecisionRouter.new(snapshot, account: @account, observability: observability(suite, scenario),
                                                              escalate: false, chain_models: [model]).decide
    row(suite, scenario, run, mode: 'model', model: model, got: decision.key, confidence: decision.first_confidence,
                              first_choice: decision.first_answers)
  rescue Captain::Runtime::DecisionRouter::UnavailableError, ArgumentError => e
    row(suite, scenario, run, mode: 'model', model: model, error: e.respond_to?(:reason) ? e.reason : e.class.name)
  end

  def pipeline_row(suite, scenario, run, snapshot)
    decision = Captain::Runtime::DecisionRouter.new(snapshot, account: @account, observability: observability(suite, scenario),
                                                              escalate: @escalation).decide
    row(suite, scenario, run, mode: 'pipeline', model: decision.decided_by, got: decision.key, confidence: decision.first_confidence,
                              escalated: decision.escalated, escalation_trigger: decision.escalation_trigger,
                              first_choice: decision.first_choice, decided_by: decision.decided_by, chain_position: decision.chain_position)
  rescue Captain::Runtime::DecisionRouter::UnavailableError => e
    row(suite, scenario, run, mode: 'pipeline', model: 'unavailable', error: e.reason)
  end

  def row(suite, scenario, run, **values)
    Row.new(suite: suite.name, scenario_id: scenario['id'], run: run, expected: scenario['expected'], **values)
  end

  # The row with its latency and the cost of the llm events it recorded.
  def measure
    last_event_id = LlmEvent.where(account_id: @account.id).maximum(:id).to_i
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    result.latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    result.cost_usd = cost_since(last_event_id).to_f
    result
  end

  def cost_since(last_event_id)
    events = LlmEvent.where(account_id: @account.id).where('id > ?', last_event_id)
                     .where(event_name: %w[llm.decision.complete llm.chat.complete]).to_a
    cost = events.sum { |event| event.estimated_cost || BigDecimal(0) }
    @spent += cost
    cost
  end

  def record(position, result)
    @rows << result
    @progress&.puts(progress_line(position, result))
    raise BudgetExceeded, 'budget_reached' if @spent >= @budget
  end

  def progress_line(position, result)
    outcome = result.error ? "error #{result.error}" : "got #{result.got} conf #{result.confidence&.round(2) || '-'}"
    escalated = result.escalated ? ' escalated' : ''
    "[#{position} run #{result.run}] #{result.scenario_id} #{result.mode} expected #{result.expected} #{outcome}#{escalated} " \
      "#{result.model} #{result.latency_ms}ms"
  end

  def observability(suite, scenario)
    { operation: 'captain.router_benchmark', source: 'benchmark', benchmark_suite: suite.name, benchmark_scenario: scenario['id'] }
  end
end
