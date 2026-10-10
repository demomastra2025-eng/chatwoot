require 'securerandom'

class Captain::Playground::SessionStore
  TTL = 24.hours.to_i
  LOCK_TTL = 15.minutes.to_i
  MAX_BYTES = 256_000

  class Busy < StandardError; end
  class Stale < StandardError; end

  def initialize(account:, user:, assistant:, mode: 'workspace')
    raise ArgumentError, 'Legacy Playground sessions must be reset' unless %w[workspace trial].include?(mode.to_s)
    raise ArgumentError, 'Assistant belongs to another workspace' unless assistant.account_id == account.id

    @key = "captain:playground:v2:#{account.id}:#{user.id}:#{assistant.id}"
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

  def permissions(session_id:)
    raw = Redis::Alfred.get("#{@key}:permissions")
    payload = JSON.parse(raw) if raw.present?
    return { 'read' => false, 'write' => false, 'generation' => nil } unless payload&.fetch('session_id', nil) == session_id

    payload
  rescue JSON::ParserError
    { 'read' => false, 'write' => false, 'generation' => nil }
  end

  # Kept outside the long model-turn lock so OFF revokes authority immediately,
  # even while a request is waiting on its model provider.
  def set_permissions(session_id:, read:, write:)
    current = self.read(session_id: session_id)
    raise Stale, 'Playground session has expired or changed' unless current

    read_enabled = ActiveModel::Type::Boolean.new.cast(read) == true
    write_enabled = read_enabled && ActiveModel::Type::Boolean.new.cast(write) == true
    previous = permissions(session_id: session_id)
    generation = previous['generation']
    generation = SecureRandom.uuid if !write_enabled || previous['write'] != write_enabled || previous['read'] != read_enabled
    payload = { 'session_id' => session_id, 'read' => read_enabled, 'write' => write_enabled, 'generation' => generation }
    Redis::Alfred.set("#{@key}:permissions", JSON.generate(payload), ex: TTL)
    payload
  end

  private

  def lock_key
    "#{@key}:lock"
  end
end
