# frozen_string_literal: true

# Cooperative cancel and deadline of one reply suggestion run. The job installs a control for the thread it runs on; the runtime
# calls RunControl.checkpoint! before each agent turn and before each tool call. Outside a suggestion run no control is set and a
# checkpoint is a no-op, so live conversations are not affected.
#
# The parts of a council run under a scope of the control (#for_parts): the same run, with a deadline of its own that leaves the
# editor its time. A part that reaches it stops with PartTimeUp, a technical failure of that part alone; the council still answers
# with the other parts. A routed suggestion that one agent answers gets the budget of one agent from the decision on (#shorten!):
# on_shorten tells the job the new deadline, so the request, the manager's timer and the hard cut of the run (HardCut) follow it.
# Every attempt of a RubyLLM call of the run, its retries too, is bounded by the time left and is not made without it (RequestTimeout).
class Captain::ReplySuggestion::RunControl
  STATE_KEY = :captain_reply_suggestion_run_control

  attr_reader :request_id, :action_ids

  class << self
    # deadline: monotonic seconds (Process.clock_gettime(Process::CLOCK_MONOTONIC)).
    # on_shorten: called with the new deadline (monotonic seconds) when #shorten! brings it closer.
    def with(request_id:, deadline:, on_shorten: nil)
      previous = ActiveSupport::IsolatedExecutionState[STATE_KEY]
      control = new(request_id, deadline, on_shorten: on_shorten)
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

  def initialize(request_id, deadline, on_shorten: nil)
    @request_id = request_id
    @deadline = deadline
    @on_shorten = on_shorten
    @cancel_checked_at = nil
    @cancelled = false
    @action_ids = []
    # The parts of a council may run on threads of their own (see Captain::Runtime::Council::ThreadScope).
    @lock = Mutex.new
  end

  def checkpoint!(stage)
    now = monotonic_now
    raise Captain::ReplySuggestion::RunAborted.new(:deadline, stage) if now >= deadline
    raise Captain::ReplySuggestion::RunAborted.new(:cancelled, stage) if cancelled?(now)
  end

  def register_action(action_id)
    @lock.synchronize { @action_ids << action_id.to_s if action_id.present? && @action_ids.exclude?(action_id.to_s) }
  end

  def seconds_left
    [deadline - monotonic_now, 0].max
  end

  # The deadline of the run (monotonic seconds).
  def deadline
    @lock.synchronize { @deadline }
  end

  # The scope of the parts of a council: their deadline leaves `reserve` seconds of the run to what follows them (the editor).
  def for_parts(reserve:)
    PartScope.new(self, [deadline - reserve, monotonic_now].max)
  end

  # The deadline comes closer, never later. Returns the deadline.
  def shorten!(seconds)
    previous, current = @lock.synchronize do
      before = @deadline
      @deadline = [@deadline, monotonic_now + seconds].min
      [before, @deadline]
    end
    @on_shorten&.call(current) if current < previous
    current
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
