# frozen_string_literal: true

# Runs one decision of the router on a thread of its own, so that it overlaps the platform safety check of the input, and hands
# the result back to the calling thread as plain data. The thread gets what the calling thread was started with (see
# Council::ThreadScope) and the same runtime caches of the settings and the model catalog. Without threads (parallel: false) the
# decision runs on the calling thread when it is awaited.
#
# While it waits, the calling thread keeps checking the reply suggestion it runs for (Captain::ReplySuggestion::RunControl): a
# cancelled or out-of-time suggestion stops at once, not when the decision comes. A turn that no longer needs the decision (a
# blocked input, a stopped suggestion) abandons it: nothing waits for it, and its thread ends on its own (bounded by the chain
# budget) with its result unread.
class Captain::Runtime::RoutingRun
  # Beyond the router's own bound (the chain budget): its database reads and events.
  WAIT_PADDING_SECONDS = 3

  def initialize(router, parallel:)
    @router = router
    @abandoned = false
    @thread = start if parallel
  end

  # The decision. Raises Captain::Runtime::DecisionRouter::UnavailableError when the router could not decide (or did not finish),
  # and Captain::ReplySuggestion::RunAborted when the suggestion was cancelled or ran out of time meanwhile.
  def await
    outcome = @thread ? joined_outcome : self.class.outcome(@router)
    raise outcome[:error] if outcome[:error]

    outcome[:decision]
  rescue Captain::Conversation::ControlGenerationStaleError
    abandon
    raise
  end

  # A turn that ends before it waits for the decision must not leave it running behind it, unless the decision was abandoned.
  def settle
    return if @abandoned || !@thread&.alive?

    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { @thread.join(wait_seconds) }
  rescue StandardError
    nil
  end

  # The turn does not need the decision any more: #settle returns at once.
  def abandon
    @abandoned = true
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

  # Joins the thread in short slices; between them the reply suggestion of the turn is checked (a no-op in a live turn).
  def joined_outcome
    deadline = monotonic_now + wait_seconds
    loop do
      remaining = deadline - monotonic_now
      return timed_out unless remaining.positive?

      slice = [remaining, Captain::ReplySuggestion::CANCEL_CHECK_INTERVAL].min
      finished = ActiveSupport::Dependencies.interlock.permit_concurrent_loads { @thread.join(slice) }
      return @thread.value if finished

      Captain::ReplySuggestion::RunControl.checkpoint!(:routing)
    end
  end

  def wait_seconds
    Captain::Runtime::DecisionRouter::Settings.chain_budget_seconds + WAIT_PADDING_SECONDS
  end

  # Out of time: the turn fails now, and #settle does not wait for the decision a second time.
  def timed_out
    abandon
    { error: Captain::Runtime::DecisionRouter::UnavailableError.new(reason: 'decision_chain_unavailable', detail: 'router_timeout') }
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
