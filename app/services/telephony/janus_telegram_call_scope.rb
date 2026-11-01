module Telephony::JanusTelegramCallScope
  def issue_for_telegram_call(server_url:, account:, user:, call:, offer:)
    descriptor = TelegramPersonal::JanusMediaConfig.normalize!(offer)
    unless call.account_id == account.id && TelegramPersonal::JanusMediaConfig.accessible_call?(call, user) &&
           matching_telegram_offer?(call, descriptor)
      raise ArgumentError, 'Janus WebSocket ticket scope does not match Telegram call'
    end

    endpoint = endpoint_for(server_url)
    verifier.generate(
      {
        version: 2, kind: 'telegram_personal_call', jti: SecureRandom.hex(24),
        account_id: account.id, user_id: user.id, call_id: call.id,
        media_session_id: call.media_session_id, room_id: descriptor['room_id'], peer_id: descriptor['peer_id'],
        origin: endpoint.fetch(:origin), path: endpoint.fetch(:path)
      },
      expires_in: ttl,
      purpose: Telephony::JanusWebsocketTicket::PURPOSE
    )
  end

  def url_for_telegram_call(server_url:, account:, user:, call:, offer:)
    uri = parse_server_url(server_url)
    query_param = Telephony::JanusWebsocketTicket::QUERY_PARAM
    query = URI.decode_www_form(uri.query.to_s).reject { |key, _value| key == query_param }
    query << [query_param, issue_for_telegram_call(server_url: server_url, account: account, user: user, call: call, offer: offer)]
    uri.query = URI.encode_www_form(query)
    uri.to_s
  end

  private

  def active_telegram_call?(payload)
    return false unless defined?(Call)

    Call.uncached do
      call = Call.telegram_personal.find_by(id: payload[:call_id], account_id: payload[:account_id], accepted_by_agent_id: payload[:user_id])
      user = User.find_by(id: payload[:user_id])
      call.present? && TelegramPersonal::JanusMediaConfig.accessible_call?(call, user) &&
        secure_match?(call.media_session_id, payload[:media_session_id]) &&
        matching_telegram_offer?(call, payload)
    end
  end

  def matching_telegram_offer?(call, descriptor)
    current = TelegramPersonal::JanusMediaConfig.normalize(call.meta.to_h['agent_offer'])
    source = descriptor.to_h.stringify_keys
    current.present? && current['room_id'] == source['room_id'] && secure_match?(current['peer_id'], source['peer_id'])
  end
end
