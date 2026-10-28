class Integrations::Medelement::RequestTelemetry
  RETENTION = 8.days.to_i
  HINTS = {
    /too many requests|rate limit|quota exceeded/i => 'rate_limit',
    /temporarily unavailable/i => 'temporarily_unavailable'
  }.freeze

  def initialize(configuration:, pool: nil, clock: -> { Time.current })
    @configuration = configuration
    @pool = pool || $alfred # rubocop:disable Style/GlobalVars
    @clock = clock
  end

  def record(operation:, lane:, duration_ms:, response: nil, error: nil)
    status = status_for(response, error)
    hour = clock.call.utc.strftime('%Y%m%d%H')
    field = [lane, operation.to_s.downcase.gsub(/[^a-z0-9]+/, '_'), status].join('|')
    pool.with do |redis|
      key = data_key(hour)
      redis.sadd(index_key(hour), identity)
      redis.expire(index_key(hour), RETENTION)
      record_count(redis, key, field, duration_ms)
      record_rejection(redis, key, response) if status == 429
      redis.expire(key, RETENTION)
    end
  rescue StandardError => e
    Rails.logger.warn("[MEDELEMENT::TELEMETRY] record failed: #{e.class.name}")
  end

  def current_hour
    read_hour(clock.call.utc.strftime('%Y%m%d%H'))
  end

  def record_pause(milliseconds)
    pool.with do |redis|
      key = data_key(clock.call.utc.strftime('%Y%m%d%H'))
      redis.hincrby(key, 'pause_count', 1)
      redis.hset(key, 'last_pause_ms', milliseconds.to_i)
      redis.expire(key, RETENTION)
    end
  rescue StandardError => e
    Rails.logger.warn("[MEDELEMENT::TELEMETRY] pause record failed: #{e.class.name}")
  end

  def read_hour(hour)
    pool.with { |redis| redis.hgetall(data_key(hour)) }
  end

  def self.report(hours:, pool: $alfred, now: Time.current) # rubocop:disable Style/GlobalVars
    hours.clamp(1, 168).times.flat_map do |offset|
      hour = (now - offset.hours).utc.strftime('%Y%m%d%H')
      pool.with do |redis|
        redis.smembers(index_key(hour)).flat_map do |identity|
          data = redis.hgetall("medelement:requests:#{hour}:#{identity}")
          data.filter_map { |field, count| report_row(hour, identity, data, field, count) if field.end_with?('|count') }
        end
      end
    end
  end

  def self.index_key(hour) = "medelement:requests:#{hour}:clinics"

  def self.report_row(hour, identity, data, field, count)
    account_id, hook_id, credential_id = identity.split(':')
    lane, operation, status, = field.split('|')
    { hour: hour, account_id: account_id, hook_id: hook_id, credential_id: credential_id, lane: lane, operation: operation,
      status: status, count: count.to_i, duration_ms: data.fetch("#{lane}|#{operation}|#{status}|duration_ms", 0).to_i,
      first_429_at_count: data['first_429_at_count']&.to_i,
      last_429_headers: data['last_429_headers'], last_429_hint: data['last_429_hint'],
      pause_count: data['pause_count']&.to_i, last_pause_ms: data['last_pause_ms']&.to_i }
  end

  private

  attr_reader :configuration, :pool, :clock

  def identity
    fingerprint = Digest::SHA256.hexdigest("#{configuration.integrator_key}\n#{configuration.company_login}").first(32)
    "#{configuration.account_id}:#{configuration.hook_id}:#{fingerprint}"
  end

  def data_key(hour) = "medelement:requests:#{hour}:#{identity}"
  def index_key(hour) = self.class.index_key(hour)

  def status_for(response, error)
    response&.code&.to_i || (error ? 'transport_error' : 'unknown')
  end

  def record_count(redis, key, field, duration_ms)
    redis.hincrby(key, 'total', 1)
    redis.hincrby(key, "#{field}|count", 1)
    redis.hincrby(key, "#{field}|duration_ms", duration_ms.to_i)
  end

  def record_rejection(redis, key, response)
    redis.hsetnx(key, 'first_429_at_count', redis.hget(key, 'total'))
    redis.hincrby(key, 'rate_limited', 1)
    redis.hset(key, 'last_429_headers', safe_headers(response).to_json)
    redis.hset(key, 'last_429_hint', body_hint(response))
  end

  def safe_headers(response)
    values = response.respond_to?(:headers) ? response.headers.to_h : response.to_hash
    values.to_h.each_with_object({}) do |(name, value), result|
      next unless name.to_s.downcase.match?(/\A(retry-after|x-ratelimit-[a-z-]+)\z/)

      text = value.to_s.first(64)
      result[name.to_s.downcase] = safe_header_value(name, text)
    end
  end

  def safe_header_value(name, value)
    return value if value.match?(/\A\d+(?:[.,]\d+)?\z/)
    return value if name.to_s.casecmp?('retry-after') && Time.httpdate(value)

    '[non-numeric]'
  rescue ArgumentError
    '[unrecognized]'
  end

  def body_hint(response)
    body = response.body.to_s.first(500)
    HINTS.each { |pattern, hint| return hint if body.match?(pattern) }
    'unclassified'
  end
end
