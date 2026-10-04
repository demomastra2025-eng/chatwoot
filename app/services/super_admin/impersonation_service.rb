# frozen_string_literal: true

require 'digest'
require 'json'

# A temporary server-side fence for super-admin customer support sessions.
class SuperAdmin::ImpersonationService
  GRANT_TTL = 2.minutes
  SESSION_TTL = 15.minutes
  CLIENT_PREFIX = 'sa-impersonation-'
  GRANT_TOKEN_PREFIX = 'sa-impersonation-grant-'
  SESSION_KEY = 'SUPER_ADMIN_IMPERSONATION_SESSION::%<client_id>s'
  GRANT_CONSUMED_KEY = 'SUPER_ADMIN_IMPERSONATION_GRANT_CONSUMED::%<digest>s'

  Grant = Struct.new(:token, :client_id, :grant_id, keyword_init: true)

  def self.issue_grant!(actor:, account:, target_user:)
    raise ArgumentError, 'An authenticated super administrator is required' unless actor.is_a?(SuperAdmin)
    raise ArgumentError, 'The target user must belong to the selected account' unless account.account_users.exists?(user_id: target_user.id)

    token = "#{GRANT_TOKEN_PREFIX}#{SecureRandom.hex(32)}"
    grant_id = SecureRandom.uuid
    client_id = "#{CLIENT_PREFIX}#{SecureRandom.hex(16)}"
    grant = {
      'type' => 'super_admin_impersonation',
      'actor_id' => actor.id,
      'account_id' => account.id,
      'target_user_id' => target_user.id,
      'client_id' => client_id,
      'grant_id' => grant_id,
      'issued_at' => Time.current.iso8601
    }
    ::Redis::Alfred.setex(sso_token_key(target_user.id, token), JSON.generate(grant), GRANT_TTL)
    Grant.new(token: token, client_id: client_id, grant_id: grant_id)
  end

  def self.impersonation_grant_token?(token)
    token.to_s.start_with?(GRANT_TOKEN_PREFIX)
  end

  def self.grant_for(user:, token:)
    return unless impersonation_grant_token?(token)

    raw = ::Redis::Alfred.get(sso_token_key(user.id, token))
    grant = JSON.parse(raw.to_s)
    return unless grant.is_a?(Hash) && grant['type'] == 'super_admin_impersonation'
    return unless grant['target_user_id'].to_s == user.id.to_s

    grant
  rescue JSON::ParserError, TypeError
    nil
  end

  def self.consume_grant!(user:, token:, grant:)
    return false unless impersonation_grant_token?(token)
    return false unless grant.is_a?(Hash) && grant['type'] == 'super_admin_impersonation'
    return false unless grant['target_user_id'].to_s == user.id.to_s
    return false unless grant_for(user: user, token: token) == grant

    digest = Digest::SHA256.hexdigest("#{user.id}:#{token}")
    consumed = ::Redis::Alfred.set(format(GRANT_CONSUMED_KEY, digest: digest), '1', nx: true, ex: GRANT_TTL.to_i)
    return false unless consumed

    session = grant.merge(
      'expires_at' => SESSION_TTL.from_now.iso8601,
      'pubsub_token' => SecureRandom.hex(32)
    )
    ::Redis::Alfred.setex(session_key(grant['client_id']), JSON.generate(session), SESSION_TTL)
    register_session_for_account!(session)
    ::Redis::Alfred.delete(sso_token_key(user.id, token))
    true
  end

  # Keep session, expiry, actor, target, account and current-membership authorization checks explicit.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def self.context_for_request(client_id, target_user_id:)
    return unless client_id.to_s.start_with?(CLIENT_PREFIX)

    raw = ::Redis::Alfred.get(session_key(client_id))
    context = JSON.parse(raw.to_s)
    return unless context.is_a?(Hash) && context['type'] == 'super_admin_impersonation'
    return unless context['target_user_id'].to_s == target_user_id.to_s
    return unless Time.zone.parse(context['expires_at'].to_s)&.future?

    actor = SuperAdmin.find_by(id: context['actor_id'])
    target_user = User.find_by(id: context['target_user_id'])
    account = Account.find_by(id: context['account_id'])
    return unless actor&.active_for_authentication? && target_user&.active_for_authentication? && account&.active?

    membership = AccountUser.find_by(user_id: target_user.id, account_id: account.id)
    return unless membership

    context.merge('account_user_id' => membership.id)
  rescue JSON::ParserError, ArgumentError, TypeError
    nil
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def self.context_for_websocket(client_id, target_user_id:, account_id:, pubsub_token:)
    context = context_for_request(client_id, target_user_id: target_user_id)
    return unless context && context['account_id'].to_s == account_id.to_s

    expected_token = context['pubsub_token'].to_s
    candidate_token = pubsub_token.to_s
    return if expected_token.blank? || expected_token.bytesize != candidate_token.bytesize
    return unless ActiveSupport::SecurityUtils.secure_compare(expected_token, candidate_token)

    context
  end

  # Scoped realtime delivery revalidates tenant, recipient, actor and session before every fanout.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def self.broadcast_to_active_sessions(account_id:, recipient_tokens:, payload:)
    account_id = account_id.to_s
    event_data = payload.is_a?(Hash) ? (payload[:data] || payload['data']) : nil
    payload_account_id = event_data.is_a?(Hash) ? (event_data[:account_id] || event_data['account_id']).to_s : ''
    return if account_id.blank? || payload_account_id != account_id

    now = Time.current.to_f
    session_index_key = account_sessions_key(account_id)
    client_ids = ::Redis::Alfred.zrangebyscore(session_index_key, now, '+inf')
    return if client_ids.empty?

    recipient_user_ids = User.where(pubsub_token: Array(recipient_tokens).compact).pluck(:id).map(&:to_s)
    return if recipient_user_ids.empty?

    client_ids.each do |client_id|
      context = active_context_for_client(client_id)
      unless context
        ::Redis::Alfred.zrem(session_index_key, client_id)
        next
      end
      next unless context['account_id'].to_s == account_id
      next unless recipient_user_ids.include?(context['target_user_id'].to_s)
      next if context['pubsub_token'].blank?

      ActionCable.server.broadcast(context['pubsub_token'], payload)
    end
  rescue StandardError => e
    Rails.logger.warn("[SuperAdmin::ImpersonationService] scoped realtime delivery failed: #{e.class.name}")
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def self.revoke!(client_id)
    return unless client_id.to_s.start_with?(CLIENT_PREFIX)

    context = active_context_for_client(client_id)
    ::Redis::Alfred.zrem(account_sessions_key(context['account_id']), client_id) if context
    ::Redis::Alfred.delete(session_key(client_id))
  end

  def self.register_session_for_account!(session)
    key = account_sessions_key(session['account_id'])
    ::Redis::Alfred.zadd(key, Time.zone.parse(session['expires_at']).to_f, session['client_id'])
    ::Redis::Alfred.expire(key, SESSION_TTL.to_i)
  end
  private_class_method :register_session_for_account!

  def self.active_context_for_client(client_id)
    raw = ::Redis::Alfred.get(session_key(client_id))
    session = JSON.parse(raw.to_s)
    return unless session.is_a?(Hash) && session['type'] == 'super_admin_impersonation'

    context_for_request(client_id, target_user_id: session['target_user_id'])
  rescue JSON::ParserError, ArgumentError, TypeError
    nil
  end
  private_class_method :active_context_for_client

  def self.account_sessions_key(account_id)
    "SUPER_ADMIN_IMPERSONATION_ACCOUNT_SESSIONS::#{account_id}"
  end
  private_class_method :account_sessions_key

  def self.sso_token_key(user_id, token)
    format(::Redis::RedisKeys::USER_SSO_AUTH_TOKEN, user_id: user_id, token: token)
  end
  private_class_method :sso_token_key

  def self.session_key(client_id)
    format(SESSION_KEY, client_id: client_id)
  end
  private_class_method :session_key
end
