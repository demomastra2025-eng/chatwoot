class Integrations::Medelement::SampleCaptureSingleAttemptPolicy
  def initialize(configuration:)
    @limiter = Integrations::Medelement::RequestRateLimiter.new(
      integrator_key: configuration.integrator_key,
      interval_ms: configuration.throttle_ms
    )
  end

  def call(operation: nil, write: false)
    raise Integrations::Medelement::SampleCapture::Refused, 'Read-only capture' if write || operation.blank?

    @limiter.wait!
    yield
  end
end
