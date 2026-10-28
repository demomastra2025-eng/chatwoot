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
  BUDGET_KEY_TEMPLATE = 'MEDELEMENT_REQUEST_BUDGET::%<fingerprint>s'.freeze
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
  BUDGET_SCRIPT = <<~LUA.freeze
    local time = redis.call('TIME')
    local second = tonumber(time[1])
    local minute = math.floor(second / 60)
    local remaining = (60 - (second % 60)) * 1000
    local pause = redis.call('PTTL', KEYS[1] .. ':pause')
    if ARGV[1] ~= 'live' and pause > 0 then return -pause end
    local total_key = KEYS[1] .. ':' .. minute .. ':total'
    local background_key = KEYS[1] .. ':' .. minute .. ':background'
    local far_key = KEYS[1] .. ':' .. minute .. ':far'
    if tonumber(redis.call('GET', total_key) or 0) >= tonumber(ARGV[2]) then return -remaining end
    if ARGV[1] ~= 'live' and tonumber(redis.call('GET', background_key) or 0) >= tonumber(ARGV[2]) - tonumber(ARGV[3]) then
      return -remaining
    end
    if ARGV[1] ~= 'live' and ARGV[1] ~= 'sync_near' and tonumber(redis.call('GET', far_key) or 0) >=
       tonumber(ARGV[2]) - tonumber(ARGV[3]) - tonumber(ARGV[4]) then return -remaining end
    redis.call('INCR', total_key)
    redis.call('EXPIRE', total_key, 120)
    if ARGV[1] ~= 'live' then
      redis.call('INCR', background_key)
      redis.call('EXPIRE', background_key, 120)
    end
    if ARGV[1] ~= 'live' and ARGV[1] ~= 'sync_near' then
      redis.call('INCR', far_key)
      redis.call('EXPIRE', far_key, 120)
    end
    return 0
  LUA
  PAUSE_SCRIPT = <<~LUA.freeze
    local strikes = redis.call('INCR', KEYS[1] .. ':strikes')
    redis.call('EXPIRE', KEYS[1] .. ':strikes', 3600)
    local seconds = tonumber(ARGV[1])
    if seconds <= 0 then seconds = math.min(300, 5 * (2 ^ math.min(strikes - 1, 6))) end
    local milliseconds = math.floor(math.min(seconds, 3600) * 1000)
    milliseconds = math.max(milliseconds, redis.call('PTTL', KEYS[1] .. ':pause'))
    redis.call('SET', KEYS[1] .. ':pause', milliseconds, 'PX', milliseconds)
    return milliseconds
  LUA

  # rubocop:disable Metrics/ParameterLists
  def initialize(integrator_key:, interval_ms:, account_login: nil, sleeper: ->(seconds) { Kernel.sleep(seconds) },
                 connection_pool: nil, clock: nil, budget_per_minute: nil, live_reserve_per_minute: nil)
    @integrator_key = integrator_key.to_s
    @account_login = account_login.to_s
    # The provider's own limit is a floor, whatever a hook setting asks for.
    @interval_ms = [interval_ms.to_i, DEFAULT_INTERVAL_MS].max
    @sleeper = sleeper
    @connection_pool = connection_pool
    @clock = clock || -> { Time.current }
    @budget_per_minute = budget_per_minute
    @live_reserve_per_minute = live_reserve_per_minute
  end
  # rubocop:enable Metrics/ParameterLists

  # Waits for the next free slot of this request type. The operation is the MedElement endpoint the request goes to.
  def wait!(operation: nil, write: false, max_wait_ms: nil, lane: :sync_far)
    default_wait = write ? MAX_INLINE_WRITE_WAIT_MS : MAX_INLINE_WAIT_MS
    delay_ms = reserve_delay_ms(operation, [max_wait_ms || default_wait, default_wait].min)
    raise BusyError.new(operation: lane_name(operation), retry_after_ms: -delay_ms, write: write) if delay_ms.negative?
    budget_delay = reserve_budget(lane) if budget_per_minute
    raise BusyError.new(operation: lane_name(operation), retry_after_ms: -budget_delay, write: write) if budget_delay&.negative?
    return unless delay_ms.positive?

    release_idle_db_connection
    sleeper.call(delay_ms.to_f / 1000)
  end

  def record_429!(retry_after_seconds: nil)
    return unless budget_per_minute

    pool.with do |connection|
      if mock_redis?(connection)
        strikes = connection.incr("#{budget_key}:strikes")
        connection.expire("#{budget_key}:strikes", 3600)
        seconds = retry_after_seconds.to_f.positive? ? retry_after_seconds.to_f : [5 * (2**(strikes - 1)), 300].min
        milliseconds = [(seconds * 1000).to_i, connection.pttl("#{budget_key}:pause")].max
        connection.set("#{budget_key}:pause", milliseconds, px: milliseconds)
        milliseconds
      else
        connection.call_with_namespace(:eval, PAUSE_SCRIPT, keys: [budget_key], argv: [retry_after_seconds.to_f])
      end
    end
  rescue Redis::BaseConnectionError, ConnectionPool::TimeoutError => e
    raise UnavailableError, "Medelement request pause is unavailable (#{e.class})"
  end

  private

  attr_reader :account_login, :clock, :connection_pool, :integrator_key, :interval_ms, :sleeper,
              :budget_per_minute, :live_reserve_per_minute

  def reserve_budget(lane)
    pool.with do |connection|
      if mock_redis?(connection)
        now = clock.call.to_i
        pause = connection.pttl("#{budget_key}:pause")
        return -pause if lane.to_s != 'live' && pause.positive?

        prefix = "#{budget_key}:#{now / 60}"
        total = "#{prefix}:total"
        background = "#{prefix}:background"
        far = "#{prefix}:far"
        remaining = (60 - (now % 60)) * 1000
        return -remaining if connection.get(total).to_i >= budget_per_minute
        return -remaining if lane.to_s != 'live' && connection.get(background).to_i >= budget_per_minute - live_reserve_per_minute
        return -remaining if !%w[live sync_near].include?(lane.to_s) &&
                             connection.get(far).to_i >= budget_per_minute - live_reserve_per_minute - near_reserve_per_minute

        connection.incr(total)
        connection.expire(total, 120)
        connection.incr(background) if lane.to_s != 'live'
        connection.expire(background, 120) if lane.to_s != 'live'
        connection.incr(far) unless %w[live sync_near].include?(lane.to_s)
        connection.expire(far, 120) unless %w[live sync_near].include?(lane.to_s)
        0
      else
        connection.call_with_namespace(:eval, BUDGET_SCRIPT, keys: [budget_key],
                                       argv: [lane.to_s, budget_per_minute, live_reserve_per_minute, near_reserve_per_minute]).to_i
      end
    end
  rescue Redis::BaseConnectionError, ConnectionPool::TimeoutError => e
    raise UnavailableError, "Medelement request budget is unavailable (#{e.class})"
  end

  def budget_key
    fingerprint = Digest::SHA256.hexdigest("#{integrator_key}\n#{account_login}").first(32)
    format(BUDGET_KEY_TEMPLATE, fingerprint: fingerprint)
  end

  def near_reserve_per_minute
    [1, (budget_per_minute - live_reserve_per_minute) / 4].max
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
