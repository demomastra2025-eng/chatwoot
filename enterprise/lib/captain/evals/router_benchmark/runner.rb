# frozen_string_literal: true

# Runs the router benchmark live against OpenRouter: every scenario becomes the same RoutingSnapshot and the same criteria the live
# router builds. Two modes, one row each:
#   model     each model of MODELS answers the question alone (one call, no chain, no escalation): raw accuracy and confidence
#   pipeline  the production decision (Captain::Runtime::DecisionRouter: the platform chain, the thresholds, the bounce guard and,
#             with ESCALATION=1, the escalation model)
# The cost of every call is read from the recorded llm events of the benchmark account; the run stops at the budget.
# fail_models makes the listed decision models fail (at once with fail_mode 'error', after the per-call timeout with 'timeout', as a
# provider that hangs would), so the pipeline rows show the fallback chain at work: which model answered and at what latency.
class Captain::Evals::RouterBenchmark::Runner
  class BudgetExceeded < StandardError; end

  FAIL_MODES = %w[error timeout].freeze
  FAILURE_KEY = :captain_router_benchmark_failure

  # Simulated provider failures of the listed models, active only on the thread of a running benchmark.
  module SimulatedFailure
    def choose(**options)
      failure = Thread.current[Captain::Evals::RouterBenchmark::Runner::FAILURE_KEY]
      return super unless failure && failure[:models].include?(options[:model])

      sleep(options[:timeout].to_f) if failure[:mode] == 'timeout'
      raise Llm::OpenRouterDecisionClient::Error, "Simulated #{failure[:mode]} of the decision model (router benchmark)."
    end
  end

  Row = Struct.new(:suite, :scenario_id, :trap, :run, :mode, :model, :expected, :got, :confidence, :escalated, :escalation_trigger,
                   :first_choice, :decided_by, :chain_position, :latency_ms, :escalation_ms, :cost_usd, :error, keyword_init: true)

  # fixture: Captain::Evals::RouterBenchmark::Fixture; account: the (throwaway) account the calls are made for; models: the models
  # called alone; chain: run the production pipeline; escalation: let the pipeline call the escalation model; only: the scenario ids
  # to play (all when empty); fail_models / fail_mode: see the class comment.
  def initialize(fixture:, account:, options: {})
    @fixture = fixture
    @account = account
    @models = Array(options[:models])
    @chain = options.fetch(:chain, true)
    @escalation = options.fetch(:escalation, true)
    @runs = [options.fetch(:runs, 1).to_i, 1].max
    @budget = BigDecimal(options.fetch(:budget_usd, 1).to_s)
    @progress = options[:progress]
    @only = Array(options[:only]).map(&:to_s)
    @failure = failure_option(options)
    @spent = BigDecimal(0)
    @rows = []
  end

  attr_reader :rows, :spent

  def call
    with_simulated_failure { play_all }
    @rows
  rescue BudgetExceeded
    @rows
  end

  private

  def play_all
    selected = @fixture.suites.flat_map do |suite|
      suite.scenarios.select { |scenario| play?(scenario) }.map { |scenario| [suite, scenario] }
    end
    total = selected.size * @runs
    (1..@runs).each do |run|
      selected.each_with_index do |(suite, scenario), index|
        play(suite, scenario, run, "#{((run - 1) * selected.size) + index + 1}/#{total}")
      end
    end
  end

  def play?(scenario)
    @only.empty? || @only.include?(scenario['id'].to_s)
  end

  def failure_option(options)
    models = Array(options[:fail_models]).map(&:to_s).compact_blank
    return if models.empty?

    mode = options.fetch(:fail_mode, 'error').to_s
    raise ArgumentError, "fail_mode must be one of #{FAIL_MODES.join(', ')}" unless FAIL_MODES.include?(mode)

    { models: models, mode: mode }.freeze
  end

  def with_simulated_failure
    return yield unless @failure

    singleton = Llm::OpenRouterDecisionClient.singleton_class
    singleton.prepend(SimulatedFailure) unless singleton.ancestors.include?(SimulatedFailure)
    Thread.current[FAILURE_KEY] = @failure
    yield
  ensure
    Thread.current[FAILURE_KEY] = nil
  end

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
                              escalation_ms: decision.escalation_ms, first_choice: decision.first_choice, decided_by: decision.decided_by,
                              chain_position: decision.chain_position)
  rescue Captain::Runtime::DecisionRouter::UnavailableError => e
    row(suite, scenario, run, mode: 'pipeline', model: 'unavailable', error: e.reason)
  end

  def row(suite, scenario, run, **values)
    Row.new(suite: suite.name, scenario_id: scenario['id'], trap: scenario['trap'].presence, run: run, expected: scenario['expected'],
            **values)
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
      "#{result.model} pos #{result.chain_position || '-'} #{result.latency_ms}ms"
  end

  def observability(suite, scenario)
    { operation: 'captain.router_benchmark', source: 'benchmark', benchmark_suite: suite.name, benchmark_scenario: scenario['id'] }
  end
end
