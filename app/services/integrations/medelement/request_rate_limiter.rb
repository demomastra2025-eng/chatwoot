# Spaces MedElement HTTP calls across Sidekiq workers and web processes per clinic and request type,
# and optionally paces background traffic across all clinics sharing one integrator key.
# MedElement allows five requests per second per request type; the default 200ms spacing matches that floor.
# If the next free slot for this request type is farther away than MAX_INLINE_WAIT_MS, the slot is not
# reserved at all: the caller gets BusyError (nothing was sent) and is expected to try again a little later instead of
# sleeping long.
class Integrations::Medelement::RequestRateLimiter # rubocop:disable Metrics/ClassLength
  UnavailableError = Class.new(StandardError)

  class BusyError < StandardError
    attr_reader :operation, :retry_after_ms

    def initialize(operation:, retry_after_ms:, write: false, paused: false)
      super("Medelement request slot is busy for #{retry_after_ms} ms")
      @operation = operation
      @retry_after_ms = retry_after_ms
      @write = write
      @paused = paused
    end

    # The refused request was a write; it was not sent either.
    def write?
      @write
    end

    # The refusal came from an active provider HTTP 429 pause rather than local pacing or minute-budget rollover.
    def paused?
      @paused
    end
  end

  KEY_TEMPLATE = 'MEDELEMENT_PROVIDER_RATE_LIMIT::%<fingerprint>s::%<operation>s'.freeze
  GLOBAL_KEY_TEMPLATE = 'MEDELEMENT_INTEGRATOR_RATE_LIMIT::%<fingerprint>s'.freeze
  BUDGET_KEY_TEMPLATE = 'MEDELEMENT_REQUEST_BUDGET::%<fingerprint>s'.freeze
  DEFAULT_INTERVAL_MS = 200
  # A caller never sleeps longer than this for a free slot. Writes and shared-integrator background queues may wait longer.
  MAX_INLINE_WAIT_MS = 3_000
  MAX_INLINE_WRITE_WAIT_MS = 10_000
  MAX_GLOBAL_WAIT_MS = 10_000
  MAX_HEADERLESS_PAUSE_SECONDS = 60
  STRIKES_TTL_SECONDS = 300
  RESERVE_SCRIPT = <<~LUA.freeze
    local redis_time = redis.call('TIME')
    local now_ms = (tonumber(redis_time[1]) * 1000) + math.floor(tonumber(redis_time[2]) / 1000)
    local interval_ms = tonumber(ARGV[1])
    local max_wait_ms = tonumber(ARGV[2])
    local next_at_ms = tonumber(redis.call('GET', KEYS[1]) or now_ms)
    local allowed_at_ms = math.max(now_ms, next_at_ms)

    if KEYS[2] then
      local next_global_ms = tonumber(redis.call('GET', KEYS[2]) or now_ms)
      allowed_at_ms = math.max(allowed_at_ms, next_global_ms)
    end

    local wait_ms = allowed_at_ms - now_ms
    if wait_ms > max_wait_ms then
      return -wait_ms
    end

    redis.call('SET', KEYS[1], allowed_at_ms + interval_ms, 'PX', wait_ms + interval_ms + 60000)
    if KEYS[2] then
      local global_interval_ms = tonumber(ARGV[3])
      redis.call('SET', KEYS[2], allowed_at_ms + global_interval_ms, 'PX', wait_ms + global_interval_ms + 60000)
    end
    return wait_ms
  LUA
  BUDGET_SCRIPT = <<~LUA.freeze
    local time = redis.call('TIME')
    local second = tonumber(time[1])
    local minute = math.floor(second / 60)
    local remaining = (60 - (second % 60)) * 1000
    local pause = redis.call('PTTL', KEYS[1] .. ':pause')
    if ARGV[1] ~= 'live' and pause > 0 then return {-pause, 1} end
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
    return minute
  LUA
  RELEASE_BUDGET_SCRIPT = <<~LUA.freeze
    local minute = tonumber(ARGV[2])
    local total_key = KEYS[1] .. ':' .. minute .. ':total'
    if tonumber(redis.call('GET', total_key) or 0) > 0 then redis.call('DECR', total_key) end
    if ARGV[1] ~= 'live' then
      local background_key = KEYS[1] .. ':' .. minute .. ':background'
      if tonumber(redis.call('GET', background_key) or 0) > 0 then redis.call('DECR', background_key) end
    end
    if ARGV[1] ~= 'live' and ARGV[1] ~= 'sync_near' then
      local far_key = KEYS[1] .. ':' .. minute .. ':far'
      if tonumber(redis.call('GET', far_key) or 0) > 0 then redis.call('DECR', far_key) end
    end
    return 0
  LUA
  PAUSE_SCRIPT = <<~LUA.freeze
    local active_pause = redis.call('PTTL', KEYS[1] .. ':pause')
    local seconds = tonumber(ARGV[1])
    if active_pause > 0 and seconds <= 0 then
      return active_pause
    end
    local strikes = tonumber(redis.call('GET', KEYS[1] .. ':strikes') or 0)
    if active_pause <= 0 then
      strikes = redis.call('INCR', KEYS[1] .. ':strikes')
      redis.call('EXPIRE', KEYS[1] .. ':strikes', 300)
    end
    if seconds <= 0 then
      local exponent = math.min(math.max(strikes - 1, 0), 4)
      seconds = math.min(60, 5 * (2 ^ exponent))
    end
    local milliseconds = math.max(1, math.floor(math.min(seconds, 3600) * 1000), active_pause)
    redis.call('SET', KEYS[1] .. ':pause', milliseconds, 'PX', milliseconds)
    return milliseconds
  LUA

  # rubocop:disable Metrics/ParameterLists
  def initialize(integrator_key:, interval_ms:, account_login: nil, sleeper: ->(seconds) { Kernel.sleep(seconds) },
                 connection_pool: nil, clock: nil, budget_per_minute: nil, live_reserve_per_minute: nil,
                 global_interval_ms: nil)
    @integrator_key = integrator_key.to_s
    @account_login = account_login.to_s
    # The provider's own limit is a floor, whatever a hook setting asks for.
    @interval_ms = [interval_ms.to_i, DEFAULT_INTERVAL_MS].max
    @global_interval_ms = global_interval_ms.to_i if global_interval_ms.to_i.positive?
    @sleeper = sleeper
    @connection_pool = connection_pool
    @clock = clock || -> { Time.current }
    @budget_per_minute = budget_per_minute
    @live_reserve_per_minute = live_reserve_per_minute
  end
  # rubocop:enable Metrics/ParameterLists

  # Waits for the next free slot of this request type. The operation is the MedElement endpoint the request goes to.
  def wait!(operation: nil, write: false, max_wait_ms: nil, lane: :sync_far)
    effective_lane = write ? :live : lane
    reserved_minute = reserve_budget_or_raise!(operation, effective_lane, write) if budget_per_minute
    delay_ms = reserve_slot_or_refund!(operation, write, max_wait_ms, effective_lane, reserved_minute)
    return unless delay_ms.positive?

    release_idle_db_connection
    sleeper.call(delay_ms.to_f / 1000)
  end

  def record_429!(retry_after_seconds: nil)
    return unless budget_per_minute

    pool.with do |connection|
      if mock_redis?(connection)
        record_429_with_mock(connection, retry_after_seconds.to_f)
      else
        connection.call_with_namespace(:eval, PAUSE_SCRIPT, keys: [budget_key], argv: [retry_after_seconds.to_f])
      end
    end
  rescue Redis::BaseConnectionError, ConnectionPool::TimeoutError => e
    raise UnavailableError, "Medelement request pause is unavailable (#{e.class})"
  end

  private

  attr_reader :account_login, :clock, :connection_pool, :global_interval_ms, :integrator_key, :interval_ms, :sleeper,
              :budget_per_minute, :live_reserve_per_minute

  def effective_max_wait_ms(write, max_wait_ms, lane)
    default_wait = write ? MAX_INLINE_WRITE_WAIT_MS : MAX_INLINE_WAIT_MS
    return [max_wait_ms, default_wait].min if max_wait_ms

    global_pacing?(lane) ? [default_wait, MAX_GLOBAL_WAIT_MS].max : default_wait
  end

  def global_pacing?(lane)
    global_interval_ms.present? && integrator_key.present? && !live_lane?(lane)
  end

  def live_lane?(lane)
    lane.to_s == 'live'
  end

  def far_lane?(lane)
    %w[live sync_near].exclude?(lane.to_s)
  end

  def reserve_budget_or_raise!(operation, lane, write)
    result, paused = reserve_budget(lane)
    raise BusyError.new(operation: lane_name(operation), retry_after_ms: -result, write: write, paused: paused) if result.negative?

    result
  end

  def reserve_slot_or_refund!(operation, write, max_wait_ms, lane, reserved_minute)
    delay_ms = reserve_delay_ms(operation, effective_max_wait_ms(write, max_wait_ms, lane), lane: lane)
    return delay_ms unless delay_ms.negative?

    release_budget(lane, reserved_minute) unless reserved_minute.nil?
    raise BusyError.new(operation: lane_name(operation), retry_after_ms: -delay_ms, write: write)
  end

  def record_429_with_mock(connection, requested_seconds)
    active_pause = connection.pttl("#{budget_key}:pause")
    return active_pause if active_pause.positive? && !requested_seconds.positive?

    strikes = next_mock_strikes(connection, active_pause)
    seconds = pause_duration_seconds(requested_seconds, strikes)
    milliseconds = [1, (seconds * 1000).to_i, active_pause].max
    connection.set("#{budget_key}:pause", milliseconds, px: milliseconds)
    milliseconds
  end

  def next_mock_strikes(connection, active_pause)
    return connection.get("#{budget_key}:strikes").to_i if active_pause.positive?

    strikes = connection.incr("#{budget_key}:strikes")
    connection.expire("#{budget_key}:strikes", STRIKES_TTL_SECONDS)
    strikes
  end

  def pause_duration_seconds(requested_seconds, strikes)
    return requested_seconds.clamp(0, 3600) if requested_seconds.positive?

    exponent = [strikes - 1, 0].max.clamp(0, 4)
    [5 * (2**exponent), MAX_HEADERLESS_PAUSE_SECONDS].min
  end

  def reserve_budget(lane)
    argv = [lane.to_s, budget_per_minute, live_reserve_per_minute, near_reserve_per_minute]
    raw = pool.with do |connection|
      next reserve_budget_with_mock(connection, lane) if mock_redis?(connection)

      connection.call_with_namespace(:eval, BUDGET_SCRIPT, keys: [budget_key], argv: argv)
    end
    raw.is_a?(Array) ? [raw.first.to_i, raw.second.to_i == 1] : [raw.to_i, false]
  rescue Redis::BaseConnectionError, ConnectionPool::TimeoutError => e
    raise UnavailableError, "Medelement request budget is unavailable (#{e.class})"
  end

  def reserve_budget_with_mock(connection, lane)
    now = clock.call.to_i
    pause = connection.pttl("#{budget_key}:pause")
    return [-pause, 1] if !live_lane?(lane) && pause.positive?

    minute = now / 60
    prefix = "#{budget_key}:#{minute}"
    return -((60 - (now % 60)) * 1000) if mock_budget_exhausted?(connection, prefix, lane)

    increment_mock_budget(connection, prefix, lane)
    minute
  end

  def mock_budget_exhausted?(connection, prefix, lane)
    return true if connection.get("#{prefix}:total").to_i >= budget_per_minute
    return true if !live_lane?(lane) && connection.get("#{prefix}:background").to_i >= background_budget_limit

    far_lane?(lane) && connection.get("#{prefix}:far").to_i >= far_budget_limit
  end

  def increment_mock_budget(connection, prefix, lane)
    increment_expiring_counter(connection, "#{prefix}:total")
    increment_expiring_counter(connection, "#{prefix}:background") unless live_lane?(lane)
    increment_expiring_counter(connection, "#{prefix}:far") if far_lane?(lane)
  end

  def increment_expiring_counter(connection, key)
    connection.incr(key)
    connection.expire(key, 120)
  end

  def background_budget_limit
    budget_per_minute - live_reserve_per_minute
  end

  def far_budget_limit
    background_budget_limit - near_reserve_per_minute
  end

  def release_budget(lane, minute)
    pool.with do |connection|
      if mock_redis?(connection)
        release_budget_with_mock(connection, "#{budget_key}:#{minute}", lane)
      else
        connection.call_with_namespace(:eval, RELEASE_BUDGET_SCRIPT, keys: [budget_key], argv: [lane.to_s, minute])
      end
    end
  rescue Redis::BaseConnectionError, ConnectionPool::TimeoutError
    nil
  end

  def release_budget_with_mock(connection, prefix, lane)
    decrement_positive_counter(connection, "#{prefix}:total")
    decrement_positive_counter(connection, "#{prefix}:background") unless live_lane?(lane)
    decrement_positive_counter(connection, "#{prefix}:far") if far_lane?(lane)
  end

  def decrement_positive_counter(connection, key)
    connection.decr(key) if connection.get(key).to_i.positive?
  end

  def budget_key
    fingerprint = Digest::SHA256.hexdigest("#{integrator_key}\n#{account_login}").first(32)
    format(BUDGET_KEY_TEMPLATE, fingerprint: fingerprint)
  end

  def global_key
    fingerprint = Digest::SHA256.hexdigest(integrator_key).first(32)
    format(GLOBAL_KEY_TEMPLATE, fingerprint: fingerprint)
  end

  def near_reserve_per_minute
    [1, background_budget_limit / 4].max
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

  def reserve_delay_ms(operation, max_wait_ms, lane:)
    keys = global_pacing?(lane) ? [key_for(operation), global_key] : [key_for(operation)]
    argv = global_pacing?(lane) ? [interval_ms, max_wait_ms, global_interval_ms] : [interval_ms, max_wait_ms]
    delay_ms = pool.with do |connection|
      next reserve_with_mock(connection, keys, max_wait_ms) if mock_redis?(connection)

      connection.call_with_namespace(:eval, RESERVE_SCRIPT, keys: keys, argv: argv)
    end
    delay_ms.to_i
  rescue Redis::BaseConnectionError, ConnectionPool::TimeoutError => e
    raise UnavailableError, "Medelement request pacing is unavailable (#{e.class})"
  end

  def reserve_with_mock(connection, keys, max_wait_ms)
    now_ms = (clock.call.to_f * 1000).to_i
    allowed_at_ms = [now_ms, connection.get(keys.first).to_i].max
    allowed_at_ms = [allowed_at_ms, connection.get(keys.second).to_i].max if keys.second
    wait_ms = allowed_at_ms - now_ms
    return -wait_ms if wait_ms > max_wait_ms

    connection.set(keys.first, allowed_at_ms + interval_ms)
    connection.set(keys.second, allowed_at_ms + global_interval_ms) if keys.second
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
