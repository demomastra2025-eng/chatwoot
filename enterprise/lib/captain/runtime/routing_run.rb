# frozen_string_literal: true

# Runs one decision of the router on a thread of its own, so that it overlaps the platform safety check of the input, and hands
# the result back to the calling thread as plain data. The thread gets what the calling thread was started with (see
# Council::ThreadScope) and the same runtime caches of the settings and the model catalog. Without threads (parallel: false) the
# decision runs on the calling thread when it is awaited.
class Captain::Runtime::RoutingRun
  # Beyond the router's own bounds (the chain budget and the escalation timeout): its database reads and events.
  WAIT_PADDING_SECONDS = 3

  def initialize(router, parallel:)
    @router = router
    @thread = start if parallel
  end

  # The decision. Raises Captain::Runtime::DecisionRouter::UnavailableError when the router could not decide (or did not finish).
  def await
    outcome = if @thread
                finished = ActiveSupport::Dependencies.interlock.permit_concurrent_loads { @thread.join(wait_seconds) }
                finished ? @thread.value : { error: timeout_error }
              else
                self.class.outcome(@router)
              end
    raise outcome[:error] if outcome[:error]

    outcome[:decision]
  end

  # A turn that ends before it waits for the decision must not leave it running behind it.
  def settle
    return unless @thread&.alive?

    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { @thread.join(wait_seconds) }
  rescue StandardError
    nil
  end

  # Plain data: the decision, or the error to raise on the calling thread.
  def self.outcome(router)
    { decision: router.decide }
  rescue Captain::Runtime::DecisionRouter::UnavailableError => e
    { error: e }
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][Router] decision failed error_class=#{e.class.name}")
    { error: Captain::Runtime::DecisionRouter::UnavailableError.new(reason: 'decision_chain_unavailable', detail: e.class.name) }
  end

  private

  def start
    router = @router
    scope = Captain::Runtime::Council::ThreadScope.capture
    Thread.new do
      Thread.current.report_on_exception = false
      scope.run do
        Llm::Config.with_runtime_cache do
          Llm::OpenRouterModelCatalog.with_model_configs_snapshot do
            Llm::OpenRouterEndpointCatalog.with_endpoint_configs_snapshot { self.class.outcome(router) }
          end
        end
      end
    end
  end

  def wait_seconds
    settings = Captain::Runtime::DecisionRouter::Settings
    settings.chain_budget_seconds + settings.escalation_timeout_seconds + WAIT_PADDING_SECONDS
  end

  def timeout_error
    Captain::Runtime::DecisionRouter::UnavailableError.new(reason: 'decision_chain_unavailable', detail: 'router_timeout')
  end
end
