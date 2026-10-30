class Integrations::Medelement::RequestRetryPolicy
  Attempt = Struct.new(:response, :error, keyword_init: true)
  READ_RETRY_LIMIT = 7
  BASE_RETRY_DELAY_SECONDS = 5
  MAX_RETRY_DELAY_SECONDS = 5.minutes.to_i
  # A command (a write and the reads right before it) has someone waiting for the answer, so a failing read is retried
  # only twice and quickly. Background reads and syncs keep the patient default above.
  COMMAND_PROFILE = { read_retry_limit: 2, base_delay_seconds: 1, max_delay_seconds: 5 }.freeze
  LOOKUP_PROFILE = { read_retry_limit: 1, base_delay_seconds: 0.25, max_delay_seconds: 0.5 }.freeze

  # rubocop:disable Metrics/ParameterLists
  def initialize(rate_limiter:, transport_errors:, sleeper:, randomizer:, clock: nil, read_retry_limit: READ_RETRY_LIMIT,
                 base_delay_seconds: BASE_RETRY_DELAY_SECONDS, max_delay_seconds: MAX_RETRY_DELAY_SECONDS,
                 deadline: nil, slot_wait_ms: nil, observer: nil)
    @rate_limiter = rate_limiter
    @transport_errors = transport_errors
    @sleeper = sleeper
    @randomizer = randomizer
    @clock = clock || -> { Time.current }
    @read_retry_limit = read_retry_limit
    @base_delay_seconds = base_delay_seconds
    @max_delay_seconds = max_delay_seconds
    @deadline = deadline
    @slot_wait_ms = slot_wait_ms
    @observer = observer
  end
  # rubocop:enable Metrics/ParameterLists

  def call(operation:, write: false, retry_429: true, lane: nil, &request)
    retry_index = 0

    loop do
      @deadline&.check!
      attempt = attempt_with_busy_wait(operation: operation, write: write, retry_429: retry_429, lane: lane, &request)
      result = resolve_attempt(attempt, operation: operation, write: write, retry_429: retry_429, retry_index: retry_index)
      return result if result

      retry_index += 1
    end
  end

  private

  attr_reader :base_delay_seconds, :clock, :max_delay_seconds, :randomizer, :rate_limiter, :read_retry_limit, :sleeper, :transport_errors

  def attempt_with_busy_wait(operation:, write:, retry_429:, lane:, &request)
    busy_retries = 0
    loop do
      return perform_attempt(operation, write, lane, &request)
    rescue Integrations::Medelement::RequestRateLimiter::BusyError => e
      raise unless wait_for_busy_slot?(error: e, write: write, retry_429: retry_429, lane: lane, busy_retries: busy_retries)

      busy_retries += 1
      wait_for_busy_slot(operation, e, busy_retries)
      @deadline&.check!
    end
  end

  def resolve_attempt(attempt, operation:, write:, retry_429:, retry_index:)
    if attempt.error
      raise attempt.error if write || retry_index >= read_retry_limit

      wait_before_retry(operation, retry_index, error: attempt.error)
      return nil
    end

    return attempt.response if final_response?(attempt.response, write: write, retry_429: retry_429, retry_index: retry_index)

    wait_before_retry(operation, retry_index, response: attempt.response)
    nil
  end

  def final_response?(response, write:, retry_429:, retry_index:)
    return true unless retryable_response?(response, write)
    return true if !retry_429 && response.code.to_i == 429

    retry_index >= read_retry_limit
  end

  def wait_for_busy_slot?(error:, write:, retry_429:, lane:, busy_retries:)
    return false if write || !retry_429 || @deadline.present?
    return false if lane.to_s == 'live'
    return false if error.retry_after_ms.to_f > max_delay_seconds.to_f * 1000

    busy_retries < read_retry_limit
  end

  def wait_for_busy_slot(operation, error, busy_retries)
    base_wait = [error.retry_after_ms.to_f / 1000.0, 0.05].max
    delay = [base_wait + randomizer.call(0.05, 0.5), max_delay_seconds.to_f].min
    Rails.logger.info(
      "[MEDELEMENT::REQUEST] waiting_for_budget operation=#{operation} " \
      "attempt=#{busy_retries}/#{read_retry_limit} wait_seconds=#{format('%.3f', delay)}"
    )
    release_idle_db_connection
    sleeper.call(delay)
  end

  def release_idle_db_connection
    return unless defined?(ActiveRecord::Base)

    ar_pool = ActiveRecord::Base.connection_pool
    return unless ar_pool.active_connection?
    return unless ActiveRecord::Base.connection.open_transactions.zero?

    ar_pool.release_connection
  rescue StandardError
    nil
  end

  # Every attempt, including a retry, takes its own slot for this request type before it goes out.
  def perform_attempt(operation, write, lane, &)
    perform_transport do
      wait_for_slot(operation, write, lane)
      @deadline&.check!
      execute_and_observe(operation, lane, &)
    end
  end

  def wait_for_slot(operation, write, lane)
    wait_options = { operation: operation, write: write }
    wait_options[:max_wait_ms] = @slot_wait_ms if @slot_wait_ms
    wait_options[:lane] = lane if lane
    rate_limiter.wait!(**wait_options)
  end

  def execute_and_observe(operation, lane)
    effective_lane = lane || :other_jobs
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = yield
    @observer&.record(operation: operation, lane: effective_lane, response: response, duration_ms: elapsed_ms(started))
    record_rate_limit_pause(response) if response.code.to_i == 429
    response
  rescue *transport_errors => e
    @observer&.record(operation: operation, lane: effective_lane, error: e, duration_ms: elapsed_ms(started))
    raise
  end

  def record_rate_limit_pause(response)
    return unless rate_limiter.respond_to?(:record_429!)

    pause_ms = rate_limiter.record_429!(retry_after_seconds: retry_after_seconds(response, maximum: 3600))
    @observer&.record_pause(pause_ms)
  end

  def elapsed_ms(started)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
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
    @deadline&.check!
    delay = [delay, @deadline.remaining].min if @deadline
    release_idle_db_connection unless @deadline
    sleeper.call(delay)
  end

  def retry_delay(retry_index, response)
    provider_delay = retry_after_seconds(response)
    return provider_delay if provider_delay

    maximum = [base_delay_seconds * (2**retry_index), max_delay_seconds].min.to_f
    randomizer.call(maximum / 2, maximum)
  end

  def retry_after_seconds(response, maximum: max_delay_seconds)
    return unless response

    raw_value = retry_after_header(response)
    return if raw_value.blank?

    numeric_value = Float(raw_value, exception: false)
    delay = numeric_value || (Time.httpdate(raw_value.to_s) - clock.call)
    delay.clamp(0, maximum).to_f
  rescue ArgumentError
    nil
  end

  def retry_after_header(response)
    return response.headers['retry-after'] if response.respond_to?(:headers)

    response['Retry-After']
  end
end
