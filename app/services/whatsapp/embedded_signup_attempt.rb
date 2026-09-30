# Short-lived server-side record of one WhatsApp Embedded Signup attempt.
#
# On phones Meta's popup is a separate tab and the dashboard tab can be suspended or
# reloaded while the customer is in Meta. The browser registers the attempt (a random
# nonce) right after opening Meta, the completion request claims it exactly once, and a
# resumed or reloaded tab asks for its outcome instead of spinning forever.
#
# The record is bound to account + user (both are part of the key), expires after TTL
# and stores no secrets: only the status, the signup type and the resulting inbox id.
# The Meta auth code is never stored; the nonce itself is kept only as a SHA-256 digest.
class Whatsapp::EmbeddedSignupAttempt
  TTL = 30.minutes
  NONCE_FORMAT = /\A[A-Za-z0-9_-]{22,128}\z/

  class InvalidNonceError < ArgumentError; end

  def self.valid_nonce?(nonce)
    nonce.is_a?(String) && NONCE_FORMAT.match?(nonce)
  end

  def initialize(account:, user:, nonce:)
    raise InvalidNonceError, 'Invalid WhatsApp signup attempt' unless self.class.valid_nonce?(nonce)
    raise ArgumentError, 'Account and user are required' if account.blank? || user.blank?

    @account = account
    @user = user
    @digest = OpenSSL::Digest::SHA256.hexdigest(nonce)
  end

  # Short, non-reversible reference for logs.
  def reference
    @digest.first(12)
  end

  # Records that the browser opened Meta for this attempt. Never overwrites a claimed attempt.
  def register(signup_type:)
    write({ 'status' => 'pending', 'signup_type' => normalized_signup_type(signup_type), 'started_at' => now }, only_if_absent: true)
  end

  # Single-use: only the first completion request for this nonce may proceed.
  def claim(signup_type:)
    return false unless Redis::Alfred.set(key(Redis::RedisKeys::WHATSAPP_EMBEDDED_SIGNUP_ATTEMPT_CLAIM), '1', nx: true, ex: TTL.to_i)

    write((state || {}).merge('status' => 'processing', 'signup_type' => normalized_signup_type(signup_type), 'claimed_at' => now))
    true
  end

  def complete!(inbox_id)
    write((state || {}).merge('status' => 'completed', 'inbox_id' => inbox_id.to_i, 'finished_at' => now))
  end

  def fail!(error_code)
    write((state || {}).merge('status' => 'failed', 'error_code' => error_code.to_s.first(64), 'finished_at' => now))
  end

  def state
    raw = Redis::Alfred.get(key(Redis::RedisKeys::WHATSAPP_EMBEDDED_SIGNUP_ATTEMPT))
    parsed = raw.present? ? JSON.parse(raw) : nil
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError
    nil
  end

  # What the dashboard may learn about its own attempt.
  def client_state
    current = state
    return { status: 'unknown' } if current.blank?

    payload = { status: current['status'], signup_type: current['signup_type'] }
    payload[:error_code] = current['error_code'] if current['status'] == 'failed'
    payload[:inbox_id] = completed_inbox_id(current) if current['status'] == 'completed'
    payload.compact
  end

  private

  def completed_inbox_id(current)
    inbox_id = current['inbox_id'].to_i
    @account.inboxes.exists?(id: inbox_id) ? inbox_id : nil
  end

  def write(payload, only_if_absent: false)
    Redis::Alfred.set(key(Redis::RedisKeys::WHATSAPP_EMBEDDED_SIGNUP_ATTEMPT), payload.to_json, nx: only_if_absent, ex: TTL.to_i)
  end

  def key(template)
    format(template, account_id: @account.id, user_id: @user.id, digest: @digest)
  end

  def normalized_signup_type(signup_type)
    type = signup_type.to_s
    Whatsapp::EmbeddedSignupService::VALID_SIGNUP_TYPES.include?(type) ? type : 'standard'
  end

  def now
    Time.current.iso8601
  end
end
