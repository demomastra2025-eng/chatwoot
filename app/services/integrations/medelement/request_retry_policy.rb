class Integrations::Medelement::RequestRetryPolicy
  Attempt = Struct.new(:response, :error, keyword_init: true)
  READ_RETRY_LIMIT = 7
  BASE_RETRY_DELAY_SECONDS = 5
  MAX_RETRY_DELAY_SECONDS = 5.minutes.to_i
  # A command (a write and the reads right before it) has someone waiting for the answer, so a failing read is retried
  # only twice and quickly. Background reads and syncs keep the patient default above.
  COMMAND_PROFILE = { read_retry_limit: 2, base_delay_seconds: 1, max_delay_seconds: 5 }.freeze

  # rubocop:disable Metrics/ParameterLists
  def initialize(rate_limiter:, transport_errors:, sleeper:, randomizer:, clock: nil, read_retry_limit: READ_RETRY_LIMIT,
                 base_delay_seconds: BASE_RETRY_DELAY_SECONDS, max_delay_seconds: MAX_RETRY_DELAY_SECONDS)
    @rate_limiter = rate_limiter
    @transport_errors = transport_errors
    @sleeper = sleeper
    @randomizer = randomizer
    @clock = clock || -> { Time.current }
    @read_retry_limit = read_retry_limit
    @base_delay_seconds = base_delay_seconds
    @max_delay_seconds = max_delay_seconds
  end
  # rubocop:enable Metrics/ParameterLists

  def call(operation:, write: false, retry_429: true, &request)
    retry_index = 0

    loop do
      attempt = perform_attempt(operation, write, &request)
      if attempt.error
        raise attempt.error if write || retry_index >= read_retry_limit

        wait_before_retry(operation, retry_index, error: attempt.error)
      else
        return attempt.response unless retryable_response?(attempt.response, write)
        return attempt.response if !retry_429 && attempt.response.code.to_i == 429
        return attempt.response if retry_index >= read_retry_limit

        wait_before_retry(operation, retry_index, response: attempt.response)
      end
      retry_index += 1
    end
  end

  private

  attr_reader :base_delay_seconds, :clock, :max_delay_seconds, :randomizer, :rate_limiter, :read_retry_limit, :sleeper, :transport_errors

  # Every attempt, including a retry, takes its own slot for this request type before it goes out.
  def perform_attempt(operation, write, &)
    perform_transport do
      rate_limiter.wait!(operation: operation, write: write)
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
      "attempt=#{retry_index + 1}/#{read_retry_limit} wait_seconds=#{format('%.3f', delay)}"
    )
    sleeper.call(delay)
  end

  def retry_delay(retry_index, response)
    provider_delay = retry_after_seconds(response)
    return provider_delay if provider_delay

    maximum = [base_delay_seconds * (2**retry_index), max_delay_seconds].min.to_f
    randomizer.call(maximum / 2, maximum)
  end

  def retry_after_seconds(response)
    return unless response

    raw_value = retry_after_header(response)
    return if raw_value.blank?

    numeric_value = Float(raw_value, exception: false)
    delay = numeric_value || (Time.httpdate(raw_value.to_s) - clock.call)
    delay.clamp(0, max_delay_seconds).to_f
  rescue ArgumentError
    nil
  end

  def retry_after_header(response)
    return response.headers['retry-after'] if response.respond_to?(:headers)

    response['Retry-After']
  end
end
