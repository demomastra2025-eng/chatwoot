# frozen_string_literal: true

# The safety net of a reply suggestion run around a hung call: the run is cut at the deadline of its RunControl plus the grace, also
# when that deadline came closer during the run (RunControl#shorten!: a routed suggestion that one agent answers is cut at the
# decision + the budget of one agent + the grace, not at the time of a council). A watchdog thread raises Expired in the run's
# thread; Expired is not a StandardError, so no rescue inside the run swallows it, and GenerateJob ends the run as failed{timeout}.
class Captain::ReplySuggestion::HardCut
  TICK_SECONDS = 0.25

  def self.run(control, grace:, &)
    new(control, grace).run(&)
  end

  def initialize(control, grace)
    @control = control
    @grace = grace.to_f
    @lock = Mutex.new
    @done = false
  end

  def run
    target = Thread.current
    watchdog = Thread.new { watch(target) }
    yield
  ensure
    @lock.synchronize { @done = true }
    watchdog&.kill
  end

  private

  def watch(target)
    loop do
      left = @control.deadline + @grace - monotonic_now
      if left <= 0
        @lock.synchronize { target.raise(Expired, 'hard limit of the reply suggestion run') unless @done }
        break
      end
      sleep([left, TICK_SECONDS].min)
    end
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
