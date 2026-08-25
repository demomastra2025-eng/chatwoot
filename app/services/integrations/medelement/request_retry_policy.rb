class Integrations::Medelement::RequestRetryPolicy
  Attempt = Struct.new(:response, :error, keyword_init: true)
  READ_RETRY_LIMIT = 7
  BASE_RETRY_DELAY_SECONDS = 5
  MAX_RETRY_DELAY_SECONDS = 5.minutes.to_i

  def initialize(rate_limiter:, transport_errors:, sleeper:, randomizer:, clock: nil)
    @rate_limiter = rate_limiter
    @transport_errors = transport_errors
    @sleeper = sleeper
    @randomizer = randomizer
    @clock = clock || -> { Time.current }
  end

  def call(operation:, write: false, &request)
    retry_index = 0

    loop do
      attempt = perform_attempt(&request)
      if attempt.error
        raise attempt.error if write || retry_index >= READ_RETRY_LIMIT

        wait_before_retry(operation, retry_index, error: attempt.error)
      else
        return attempt.response unless retryable_response?(attempt.response, write)
        return attempt.response if retry_index >= READ_RETRY_LIMIT

        wait_before_retry(operation, retry_index, response: attempt.response)
      end
      retry_index += 1
    end
  end

  private

  attr_reader :clock, :randomizer, :rate_limiter, :sleeper, :transport_errors

  def perform_attempt(&)
    perform_transport do
      rate_limiter.wait!
      yield
    end
  end

  def perform_transport
    Attempt.new(response: yield)
  rescue *transport_errors => e
    Attempt.new(error: e)
  end

  def retryable_response?(response, write)
    return false if write

    status = response.code.to_i
    status == 408 || status == 429 || status >= 500
  end

  def wait_before_retry(operation, retry_index, response: nil, error: nil)
    delay = retry_delay(retry_index, response)
    reason = response ? "status=#{response.code.to_i}" : "transport=#{error.class.name}"
    Rails.logger.warn(
      "[MEDELEMENT::REQUEST] retrying operation=#{operation} #{reason} " \
      "attempt=#{retry_index + 1}/#{READ_RETRY_LIMIT} wait_seconds=#{format('%.3f', delay)}"
    )
    sleeper.call(delay)
  end

  def retry_delay(retry_index, response)
    provider_delay = retry_after_seconds(response)
    return provider_delay if provider_delay

    maximum = [BASE_RETRY_DELAY_SECONDS * (2**retry_index), MAX_RETRY_DELAY_SECONDS].min.to_f
    randomizer.call(maximum / 2, maximum)
  end

  def retry_after_seconds(response)
    return unless response

    raw_value = retry_after_header(response)
    return if raw_value.blank?

    numeric_value = Float(raw_value, exception: false)
    delay = numeric_value || (Time.httpdate(raw_value.to_s) - clock.call)
    delay.clamp(0, MAX_RETRY_DELAY_SECONDS).to_f
  rescue ArgumentError
    nil
  end

  def retry_after_header(response)
    return response.headers['retry-after'] if response.respond_to?(:headers)

    response['Retry-After']
  end
end
