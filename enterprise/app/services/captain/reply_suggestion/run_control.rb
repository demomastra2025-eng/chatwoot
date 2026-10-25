# frozen_string_literal: true

# Cooperative cancel and deadline of one reply suggestion run. The job installs a control for the thread it runs on; the runtime
# calls RunControl.checkpoint! before each agent turn and before each tool call. Outside a suggestion run no control is set and a
# checkpoint is a no-op, so live conversations are not affected.
class Captain::ReplySuggestion::RunControl
  STATE_KEY = :captain_reply_suggestion_run_control

  attr_reader :request_id, :action_ids

  class << self
    # deadline: monotonic seconds (Process.clock_gettime(Process::CLOCK_MONOTONIC)).
    def with(request_id:, deadline:)
      previous = ActiveSupport::IsolatedExecutionState[STATE_KEY]
      control = new(request_id, deadline)
      ActiveSupport::IsolatedExecutionState[STATE_KEY] = control
      yield control
    ensure
      ActiveSupport::IsolatedExecutionState[STATE_KEY] = previous
    end

    def current
      ActiveSupport::IsolatedExecutionState[STATE_KEY]
    end

    # The control of the run on another thread of the same run (see Captain::Runtime::Council::ThreadScope); nil sets none.
    def adopt(control)
      previous = ActiveSupport::IsolatedExecutionState[STATE_KEY]
      ActiveSupport::IsolatedExecutionState[STATE_KEY] = control
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[STATE_KEY] = previous
    end

    def checkpoint!(stage)
      current&.checkpoint!(stage)
    end

    # The approval cards prepared by the run: a run that does not finish discards them (no partial results).
    def register_action(action_id)
      current&.register_action(action_id)
    end
  end

  def initialize(request_id, deadline)
    @request_id = request_id
    @deadline = deadline
    @cancel_checked_at = nil
    @cancelled = false
    @action_ids = []
    # The parts of a council may run on threads of their own (see Captain::Runtime::Council::ThreadScope).
    @lock = Mutex.new
  end

  def checkpoint!(stage)
    now = monotonic_now
    raise Captain::ReplySuggestion::RunAborted.new(:deadline, stage) if now >= @deadline
    raise Captain::ReplySuggestion::RunAborted.new(:cancelled, stage) if cancelled?(now)
  end

  def register_action(action_id)
    @lock.synchronize { @action_ids << action_id.to_s if action_id.present? && @action_ids.exclude?(action_id.to_s) }
  end

  def seconds_left
    [@deadline - monotonic_now, 0].max
  end

  private

  # Redis is asked at most once per CANCEL_CHECK_INTERVAL, whichever thread asks; a cancel once seen stays seen.
  def cancelled?(now)
    @lock.synchronize do
      return true if @cancelled
      return false if @cancel_checked_at && now - @cancel_checked_at < Captain::ReplySuggestion::CANCEL_CHECK_INTERVAL

      @cancel_checked_at = now
      @cancelled = Captain::ReplySuggestion::RequestStore.cancel_requested?(@request_id)
    end
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
