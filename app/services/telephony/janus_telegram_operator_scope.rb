module Telephony::JanusTelegramOperatorScope
  VERSION = 3
  KIND = 'telegram_operator_sip'.freeze

  def validated_telegram_operator_binding!(binding:, account:)
    scoped = Telephony::TelegramOperatorBinding.uncached do
      Telephony::TelegramOperatorBinding.connected.find_by(
        id: binding&.id, account_id: account&.id, user_id: binding&.user_id
      )
    end
    return scoped if scoped.present? && scoped.account.feature_enabled?('channel_voice')

    raise ArgumentError, 'Janus Telegram operator requires a connected account binding'
  end

  def issue_for_telegram_operator(server_url:, sip_profile:, binding:, registration_instance_id:)
    endpoint = endpoint_for(server_url)
    payload = {
      version: Telephony::JanusTelegramOperatorScope::VERSION, kind: Telephony::JanusTelegramOperatorScope::KIND,
      jti: SecureRandom.hex(24), binding_id: binding&.id, account_id: binding&.account_id, user_id: binding&.user_id,
      sip_profile_id: sip_profile&.id, registration_instance_id: registration_instance_id,
      path: endpoint.fetch(:path)
    }
    raise ArgumentError, 'Janus Telegram operator scope or registration lease is invalid' unless active_telegram_operator?(payload)

    verifier.generate(payload, expires_in: ttl, purpose: Telephony::JanusWebsocketTicket::PURPOSE)
  end

  def url_for_telegram_operator(server_url:, **scope)
    uri = parse_server_url(server_url)
    query_param = Telephony::JanusWebsocketTicket::QUERY_PARAM
    query = URI.decode_www_form(uri.query.to_s).reject { |key, _value| key == query_param }
    query << [query_param, issue_for_telegram_operator(server_url: server_url, **scope)]
    uri.query = URI.encode_www_form(query)
    uri.to_s
  end

  private

  def telegram_operator_payload?(payload)
    payload[:version] == Telephony::JanusTelegramOperatorScope::VERSION && payload[:kind] == Telephony::JanusTelegramOperatorScope::KIND
  end

  def active_telegram_operator?(payload)
    Telephony::SipProfile.uncached do
      binding = Telephony::TelegramOperatorBinding.connected.find_by(
        id: payload[:binding_id], account_id: payload[:account_id], user_id: payload[:user_id]
      )
      profile = Telephony::SipProfile.where(
        id: payload[:sip_profile_id], account_id: payload[:account_id], user_id: payload[:user_id],
        enabled: true, availability_mode: 'browser_webphone'
      ).where.not(status: Telephony::JanusWebsocketTicket::REVOKED_PROFILE_STATUSES).first
      binding.present? && binding.account.feature_enabled?('channel_voice') && profile.present? &&
        Telephony::ProviderPolicy.enabled_for_profile?(profile) && operator_registration_lease?(profile, binding, payload)
    end
  end

  def operator_registration_lease?(profile, binding, payload)
    lease = profile.metadata.to_h.fetch('browser_registration_lease', {}).to_h.stringify_keys
    profile.browser_registration_lease_valid?(payload[:registration_instance_id]) &&
      secure_match?(lease['client_instance_id'], "telegram_softphone:#{binding.id}") &&
      secure_match?(lease['browser_instance_id'], "telegram_softphone:#{binding.user_id}") &&
      lease['user_id'].to_s == binding.user_id.to_s
  end
end
