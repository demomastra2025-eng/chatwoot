require 'securerandom'

class Captain::Playground::SessionStore
  TTL = 24.hours.to_i
  LOCK_TTL = 15.minutes.to_i
  MAX_BYTES = 256_000

  class Busy < StandardError; end
  class Stale < StandardError; end

  ISOLATED_PREFIX = 'iso-'.freeze
  ISOLATED_ID_PATTERN = /\Aiso-[A-Za-z0-9_-]{8,64}\z/

  # One primary browser Playground session per user and workspace, plus isolated per-request handles (iso-<uuid>) for API/MCP callers.
  def initialize(account:, user:, mode: 'workspace', session_id: nil)
    raise ArgumentError, 'Legacy Playground sessions must be reset' unless %w[workspace trial].include?(mode.to_s)

    @key = "captain:playground:v3:#{account.id}:#{user.id}"
    @lock_session_id = session_id.to_s if isolated_id?(session_id)
  end

  def with_lock
    token = SecureRandom.uuid
    raise Busy, 'Playground session is already running' unless Redis::Alfred.set(lock_key, token, nx: true, ex: LOCK_TTL)

    yield
  ensure
    Redis::Alfred.delete_if_value(lock_key, token) if token
  end

  def read(session_id: nil)
    raw = Redis::Alfred.get(storage_key_for(session_id))
    data = JSON.parse(raw) if raw.present? && raw.bytesize <= MAX_BYTES
    raise Stale, 'Playground session has expired or changed' if session_id.present? && data&.fetch('id', nil) != session_id

    data
  rescue JSON::ParserError
    raise Stale, 'Playground session has expired or changed'
  end

  def write(data)
    json = JSON.generate(data)
    raise ArgumentError, 'Playground scenario is too large' if json.bytesize > MAX_BYTES

    Redis::Alfred.set(storage_key_for(data['id']), json, ex: TTL)
  end

  def delete_isolated(session_id)
    return unless isolated_id?(session_id)

    target_key = storage_key_for(session_id)
    Redis::Alfred.delete(target_key)
    Redis::Alfred.delete("#{target_key}:permissions")
  end

  def permissions(session_id:)
    raw = Redis::Alfred.get("#{storage_key_for(session_id)}:permissions")
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
    Redis::Alfred.set("#{storage_key_for(session_id)}:permissions", JSON.generate(payload), ex: TTL)
    payload
  end

  private

  def isolated_id?(session_id)
    session_id.to_s.match?(ISOLATED_ID_PATTERN)
  end

  def storage_key_for(session_id)
    if session_id.to_s.start_with?(ISOLATED_PREFIX)
      raise Stale, 'Playground session has expired or changed' unless isolated_id?(session_id)

      return "#{@key}:#{session_id}"
    end

    @key
  end

  def lock_key
    "#{storage_key_for(@lock_session_id)}:lock"
  end
end
