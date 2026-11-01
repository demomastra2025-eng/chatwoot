require 'uri'

class TelegramPersonal::JanusMediaConfig
  TRANSPORT = 'janus_audiobridge'.freeze
  MAX_ROOM_ID = (2**53) - 1
  CREDENTIAL_KEYS = %w[pin token peer_id].freeze

  class InvalidConfig < StandardError; end

  class << self
    def normalize(offer)
      return unless offer.respond_to?(:to_h)

      source = offer.to_h.stringify_keys
      return unless source['transport'] == TRANSPORT && valid_room_id?(source['room_id'])
      return unless CREDENTIAL_KEYS.all? { |key| valid_credential?(source[key]) }

      source.slice('transport', 'room_id', *CREDENTIAL_KEYS)
    end

    def normalize!(offer)
      normalize(offer) || raise(InvalidConfig, 'Telegram calls require Janus media')
    end

    def browser_payload(call:, user:, offer: nil)
      return unless accessible_call?(call, user)

      descriptor = normalize!(offer || call.meta.to_h['agent_offer'])
      descriptor.merge(
        'server' => Telephony::JanusWebsocketTicket.url_for_telegram_call(
          server_url: server_url!, account: call.account, user: user, call: call, offer: descriptor
        ),
        'ice_servers' => ice_servers
      )
    end

    def accessible_call?(call, user)
      return false unless owned_active_call?(call, user)

      membership = AccountUser.find_by(account_id: call.account_id, user_id: user.id)
      return false unless membership && call.conversation

      ConversationPolicy.new({ user: user, account: call.account, account_user: membership }, call.conversation).show?
    end

    def server_url!
      url = ENV.fetch('TELEPHONY_JANUS_WS_URL', '').presence ||
            ENV.fetch('JANUS_PUBLIC_WS_URL', '').presence || frontend_server_url
      uri = URI.parse(url.to_s)
      return url if valid_server_uri?(uri)

      raise InvalidConfig, 'Shared Janus WebSocket endpoint is not configured'
    rescue URI::InvalidURIError
      raise InvalidConfig, 'Shared Janus WebSocket endpoint is not configured'
    end

    private

    def owned_active_call?(call, user)
      return false if call.blank? || user.blank? || !call.telegram_personal?

      call.accepted_by_agent_id == user.id && call.media_session_id.present? && active_media_state?(call)
    end

    def active_media_state?(call)
      call.in_progress? || (call.outgoing? && call.ringing? && call.meta.to_h['outbound_prepare_pending'] == true)
    end

    def valid_server_uri?(uri)
      uri.scheme.in?(%w[ws wss]) && uri.host.present? && uri.userinfo.blank? && uri.fragment.blank?
    end

    def valid_room_id?(value)
      value.is_a?(Integer) && value.positive? && value <= MAX_ROOM_ID
    end

    def valid_credential?(value)
      value.is_a?(String) && value.present? && value.bytesize <= 512 && !value.match?(/[[:cntrl:]]/)
    end

    def frontend_server_url
      uri = URI.parse(ENV.fetch('FRONTEND_URL', ''))
      return unless uri.scheme.in?(%w[http https]) && uri.host.present?

      uri.scheme = uri.scheme == 'http' ? 'ws' : 'wss'
      uri.path = '/janus-sipuni'
      uri.query = nil
      uri.fragment = nil
      uri.to_s
    end

    def ice_servers
      parsed = JSON.parse(unquote_json(ENV.fetch('TELEPHONY_JANUS_ICE_SERVERS_JSON', '').strip))
      parsed.is_a?(Array) ? parsed : []
    rescue JSON::ParserError
      []
    end

    def unquote_json(value)
      quote = value[0]
      quoted = value.length >= 2 && ["'", '"'].include?(quote) && value.end_with?(quote)
      quoted ? value[1...-1] : value
    end
  end
end
