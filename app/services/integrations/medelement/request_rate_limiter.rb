class Integrations::Medelement::RequestRateLimiter
  UnavailableError = Class.new(StandardError)
  KEY_TEMPLATE = 'MEDELEMENT_PROVIDER_RATE_LIMIT::%<fingerprint>s'.freeze
  RESERVE_SCRIPT = <<~LUA.freeze
    local redis_time = redis.call('TIME')
    local now_ms = (tonumber(redis_time[1]) * 1000) + math.floor(tonumber(redis_time[2]) / 1000)
    local interval_ms = tonumber(ARGV[1])
    local next_at_ms = tonumber(redis.call('GET', KEYS[1]) or now_ms)
    local allowed_at_ms = math.max(now_ms, next_at_ms)
    local wait_ms = allowed_at_ms - now_ms
    local following_at_ms = allowed_at_ms + interval_ms
    local ttl_ms = wait_ms + interval_ms + 60000

    redis.call('SET', KEYS[1], following_at_ms, 'PX', ttl_ms)
    return wait_ms
  LUA

  def initialize(integrator_key:, interval_ms:, sleeper: ->(seconds) { Kernel.sleep(seconds) }, connection_pool: nil, clock: nil)
    @integrator_key = integrator_key.to_s
    @interval_ms = interval_ms.to_i
    @sleeper = sleeper
    @connection_pool = connection_pool
    @clock = clock || -> { Time.current }
  end

  def wait!
    return if interval_ms <= 0

    delay_ms = reserve_delay_ms
    sleeper.call(delay_ms.to_f / 1000) if delay_ms.positive?
  end

  private

  attr_reader :clock, :connection_pool, :integrator_key, :interval_ms, :sleeper

  def reserve_delay_ms
    delay_ms = pool.with do |connection|
      next reserve_with_mock(connection) if mock_redis?(connection)

      connection.call_with_namespace(:eval, RESERVE_SCRIPT, keys: [key], argv: [interval_ms])
    end
    delay_ms.to_i
  rescue Redis::BaseConnectionError, ConnectionPool::TimeoutError => e
    raise UnavailableError, "Medelement request pacing is unavailable (#{e.class})"
  end

  def reserve_with_mock(connection)
    now_ms = (clock.call.to_f * 1000).to_i
    next_at_ms = connection.get(key).to_i
    allowed_at_ms = [now_ms, next_at_ms].max
    connection.set(key, allowed_at_ms + interval_ms)
    allowed_at_ms - now_ms
  end

  def mock_redis?(connection)
    defined?(::MockRedis) && connection.redis.instance_of?(::MockRedis)
  end

  def pool
    connection_pool || $alfred # rubocop:disable Style/GlobalVars
  end

  def key
    fingerprint = Digest::SHA256.hexdigest(integrator_key).first(32)
    format(KEY_TEMPLATE, fingerprint: fingerprint)
  end
end
