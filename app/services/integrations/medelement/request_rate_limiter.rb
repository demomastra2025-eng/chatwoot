# Spaces MedElement HTTP calls across Sidekiq workers and web processes per clinic and request type.
# MedElement allows five requests per second per request type; the default 200ms spacing matches that floor.
# If the next free slot for this request type is farther away than MAX_INLINE_WAIT_MS, the slot is not
# reserved at all: the caller gets BusyError (nothing was sent) and is expected to try again a little later instead of
# sleeping long.
class Integrations::Medelement::RequestRateLimiter
  UnavailableError = Class.new(StandardError)

  class BusyError < StandardError
    attr_reader :operation, :retry_after_ms

    def initialize(operation:, retry_after_ms:, write: false)
      super("Medelement request slot is busy for #{retry_after_ms} ms")
      @operation = operation
      @retry_after_ms = retry_after_ms
      @write = write
    end

    # The refused request was a write; it was not sent either.
    def write?
      @write
    end
  end

  KEY_TEMPLATE = 'MEDELEMENT_PROVIDER_RATE_LIMIT::%<fingerprint>s::%<operation>s'.freeze
  DEFAULT_INTERVAL_MS = 200
  # A caller never sleeps longer than this for a free slot. Writes may wait a little longer than reads.
  MAX_INLINE_WAIT_MS = 3_000
  MAX_INLINE_WRITE_WAIT_MS = 10_000
  RESERVE_SCRIPT = <<~LUA.freeze
    local redis_time = redis.call('TIME')
    local now_ms = (tonumber(redis_time[1]) * 1000) + math.floor(tonumber(redis_time[2]) / 1000)
    local interval_ms = tonumber(ARGV[1])
    local max_wait_ms = tonumber(ARGV[2])
    local next_at_ms = tonumber(redis.call('GET', KEYS[1]) or now_ms)
    local allowed_at_ms = math.max(now_ms, next_at_ms)
    local wait_ms = allowed_at_ms - now_ms

    if wait_ms > max_wait_ms then
      return -wait_ms
    end

    local following_at_ms = allowed_at_ms + interval_ms
    local ttl_ms = wait_ms + interval_ms + 60000

    redis.call('SET', KEYS[1], following_at_ms, 'PX', ttl_ms)
    return wait_ms
  LUA

  # rubocop:disable Metrics/ParameterLists
  def initialize(integrator_key:, interval_ms:, account_login: nil, sleeper: ->(seconds) { Kernel.sleep(seconds) },
                 connection_pool: nil, clock: nil)
    @integrator_key = integrator_key.to_s
    @account_login = account_login.to_s
    # The provider's own limit is a floor, whatever a hook setting asks for.
    @interval_ms = [interval_ms.to_i, DEFAULT_INTERVAL_MS].max
    @sleeper = sleeper
    @connection_pool = connection_pool
    @clock = clock || -> { Time.current }
  end
  # rubocop:enable Metrics/ParameterLists

  # Waits for the next free slot of this request type. The operation is the MedElement endpoint the request goes to.
  def wait!(operation: nil, write: false)
    delay_ms = reserve_delay_ms(operation, write ? MAX_INLINE_WRITE_WAIT_MS : MAX_INLINE_WAIT_MS)
    raise BusyError.new(operation: lane_name(operation), retry_after_ms: -delay_ms, write: write) if delay_ms.negative?
    return unless delay_ms.positive?

    release_idle_db_connection
    sleeper.call(delay_ms.to_f / 1000)
  end

  private

  attr_reader :account_login, :clock, :connection_pool, :integrator_key, :interval_ms, :sleeper

  def release_idle_db_connection
    return unless defined?(ActiveRecord::Base)

    ar_pool = ActiveRecord::Base.connection_pool
    return unless ar_pool.active_connection?
    return unless ActiveRecord::Base.connection.open_transactions.zero?

    ar_pool.release_connection
  rescue StandardError
    nil
  end

  def reserve_delay_ms(operation, max_wait_ms)
    key = key_for(operation)
    delay_ms = pool.with do |connection|
      next reserve_with_mock(connection, key, max_wait_ms) if mock_redis?(connection)

      connection.call_with_namespace(:eval, RESERVE_SCRIPT, keys: [key], argv: [interval_ms, max_wait_ms])
    end
    delay_ms.to_i
  rescue Redis::BaseConnectionError, ConnectionPool::TimeoutError => e
    raise UnavailableError, "Medelement request pacing is unavailable (#{e.class})"
  end

  def reserve_with_mock(connection, key, max_wait_ms)
    now_ms = (clock.call.to_f * 1000).to_i
    next_at_ms = connection.get(key).to_i
    allowed_at_ms = [now_ms, next_at_ms].max
    wait_ms = allowed_at_ms - now_ms
    return -wait_ms if wait_ms > max_wait_ms

    connection.set(key, allowed_at_ms + interval_ms)
    wait_ms
  end

  def mock_redis?(connection)
    defined?(::MockRedis) && connection.redis.instance_of?(::MockRedis)
  end

  def pool
    connection_pool || $alfred # rubocop:disable Style/GlobalVars
  end

  # One lane per account (integrator key plus clinic login) and request type. Secrets never appear in the key.
  def key_for(operation)
    fingerprint = Digest::SHA256.hexdigest("#{integrator_key}\n#{account_login}").first(32)
    format(KEY_TEMPLATE, fingerprint: fingerprint, operation: lane_name(operation))
  end

  def lane_name(operation)
    operation.to_s.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/\A_|_\z/, '').presence || 'default'
  end
end
