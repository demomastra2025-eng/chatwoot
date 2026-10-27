class Integrations::Medelement::RequestDeadline
  def initialize(seconds: 5, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @clock = clock
    @ends_at = clock.call + seconds
  end

  def remaining
    [@ends_at - @clock.call, 0].max
  end

  def check!
    raise Timeout::Error, 'Medelement interactive request deadline exceeded' if remaining <= 0
  end
end
