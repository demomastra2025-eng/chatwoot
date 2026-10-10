require 'securerandom'

class Captain::Playground::SessionStore
  TTL = 24.hours.to_i
  LOCK_TTL = 15.minutes.to_i
  MAX_BYTES = 256_000

  class Busy < StandardError; end
  class Stale < StandardError; end

  def initialize(account:, user:, assistant:, mode:)
    raise ArgumentError, 'Invalid Playground mode' unless %w[trial live].include?(mode.to_s)
    raise ArgumentError, 'Assistant belongs to another workspace' unless assistant.account_id == account.id

    @key = "captain:playground:v1:#{account.id}:#{user.id}:#{assistant.id}:#{mode}"
  end

  def with_lock
    token = SecureRandom.uuid
    raise Busy, 'Playground session is already running' unless Redis::Alfred.set(lock_key, token, nx: true, ex: LOCK_TTL)

    yield
  ensure
    Redis::Alfred.delete_if_value(lock_key, token) if token
  end

  def read(session_id: nil)
    raw = Redis::Alfred.get(@key)
    data = JSON.parse(raw) if raw.present? && raw.bytesize <= MAX_BYTES
    raise Stale, 'Playground session has expired or changed' if session_id.present? && data&.fetch('id', nil) != session_id

    data
  rescue JSON::ParserError
    raise Stale, 'Playground session has expired or changed'
  end

  def write(data)
    json = JSON.generate(data)
    raise ArgumentError, 'Playground scenario is too large' if json.bytesize > MAX_BYTES

    Redis::Alfred.set(@key, json, ex: TTL)
  end

  private

  def lock_key
    "#{@key}:lock"
  end
end
