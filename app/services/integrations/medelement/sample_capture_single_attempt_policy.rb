class Integrations::Medelement::SampleCaptureSingleAttemptPolicy
  def initialize(configuration:)
    @limiter = Integrations::Medelement::RequestRateLimiter.new(
      integrator_key: configuration.integrator_key,
      account_login: configuration.company_login,
      interval_ms: configuration.throttle_ms,
      budget_per_minute: configuration.request_budget_per_minute,
      live_reserve_per_minute: configuration.live_reserve_per_minute
    )
    @telemetry = Integrations::Medelement::RequestTelemetry.new(configuration: configuration)
  end

  def call(operation: nil, write: false, lane: nil, **_options)
    raise Integrations::Medelement::SampleCapture::Refused, 'Read-only capture' if write || operation.blank?

    caller_lane = lane || :other_jobs
    @limiter.wait!(operation: operation, lane: caller_lane)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = yield
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    @telemetry.record(operation: operation, lane: caller_lane, response: response, duration_ms: duration_ms)
    return response unless response.code.to_i == 429

    pause_ms = @limiter.record_429!
    @telemetry.record_pause(pause_ms)
    response
  rescue StandardError => e
    if started
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      @telemetry.record(operation: operation, lane: caller_lane, error: e, duration_ms: duration_ms)
    end
    raise
  end
end
