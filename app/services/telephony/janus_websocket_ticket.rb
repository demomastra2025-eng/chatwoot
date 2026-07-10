require 'digest'
require 'securerandom'
require 'uri'

class Telephony::JanusWebsocketTicket
  PURPOSE = :telephony_janus_websocket
  QUERY_PARAM = 'janus_ticket'.freeze
  DEFAULT_TTL = 2.minutes
  MIN_TTL_SECONDS = 30
  MAX_TTL_SECONDS = 5.minutes.to_i
  REVOKED_PROFILE_STATUSES = %w[disabled deleting failed].freeze

  class << self
    def issue(server_url:, account:, user:, sip_profile:)
      validate_scope!(account: account, user: user, sip_profile: sip_profile)
      endpoint = endpoint_for(server_url)

      verifier.generate(
        {
          version: 1,
          jti: SecureRandom.hex(24),
          account_id: account.id,
          user_id: user.id,
          sip_profile_id: sip_profile.id,
          origin: endpoint.fetch(:origin),
          path: endpoint.fetch(:path)
        },
        expires_in: ttl,
        purpose: PURPOSE
      )
    end

    def url_for(server_url:, account:, user:, sip_profile:)
      uri = parse_server_url(server_url)
      query = URI.decode_www_form(uri.query.to_s).reject { |key, _value| key == QUERY_PARAM }
      query << [QUERY_PARAM, issue(server_url: server_url, account: account, user: user, sip_profile: sip_profile)]
      uri.query = URI.encode_www_form(query)
      uri.to_s
    end

    def valid?(ticket:, origin:, path:)
      payload = verified_payload(ticket)
      payload.present? && valid_payload?(payload, origin: origin, path: path)
    end

    def authorize?(ticket:, origin:, path:)
      payload = verified_payload(ticket)
      return false unless payload.present? && valid_payload?(payload, origin: origin, path: path)

      consume_once?(payload.fetch(:jti))
    end

    private

    def valid_payload?(payload, origin:, path:)
      payload[:version].to_i == 1 &&
        payload[:jti].present? &&
        secure_match?(payload[:origin], normalize_origin(origin)) &&
        secure_match?(payload[:path], normalize_path(path)) &&
        active_profile?(payload)
    end

    def verified_payload(ticket)
      payload = verifier.verified(ticket.to_s, purpose: PURPOSE)
      payload.is_a?(Hash) ? payload.with_indifferent_access : nil
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    def active_profile?(payload)
      Telephony::SipProfile.uncached do
        profile_exists = Telephony::SipProfile
                         .where(
                           id: payload[:sip_profile_id],
                           account_id: payload[:account_id],
                           user_id: payload[:user_id],
                           enabled: true,
                           availability_mode: 'browser_webphone'
                         )
                         .where.not(status: REVOKED_PROFILE_STATUSES)
                         .exists?
        account_user_exists = AccountUser.exists?(account_id: payload[:account_id], user_id: payload[:user_id])
        profile_exists && account_user_exists
      end
    end

    def consume_once?(jti)
      Redis::Alfred.set(
        "telephony:janus_ws_ticket:used:#{Digest::SHA256.hexdigest(jti.to_s)}",
        true,
        nx: true,
        ex: ttl.to_i
      ).present?
    rescue StandardError => e
      Rails.logger.error(event: 'janus_ws_ticket_consume_failed', error: e.class.name)
      false
    end

    def validate_scope!(account:, user:, sip_profile:)
      valid = account.present? && user.present? && sip_profile.present? &&
              sip_profile.account_id == account.id && sip_profile.user_id == user.id
      raise ArgumentError, 'Janus WebSocket ticket scope does not match SIP profile' unless valid
    end

    def endpoint_for(server_url)
      uri = parse_server_url(server_url)
      {
        origin: origin_for(uri),
        path: normalize_path(uri.path)
      }
    end

    def parse_server_url(server_url)
      uri = URI.parse(server_url.to_s)
      raise URI::InvalidURIError, 'Janus WebSocket URL must use ws or wss' unless uri.scheme.in?(%w[ws wss]) && uri.host.present?

      uri
    end

    def origin_for(uri)
      scheme = uri.scheme == 'wss' ? 'https' : 'http'
      default_port = scheme == 'https' ? 443 : 80
      port = uri.port == default_port ? nil : ":#{uri.port}"
      "#{scheme}://#{uri.host}#{port}"
    end

    def normalize_origin(origin)
      uri = URI.parse(origin.to_s)
      return unless uri.scheme.in?(%w[http https]) && uri.host.present?

      default_port = uri.scheme == 'https' ? 443 : 80
      port = uri.port == default_port ? nil : ":#{uri.port}"
      "#{uri.scheme}://#{uri.host}#{port}"
    end

    def normalize_path(path)
      value = path.to_s.split('?', 2).first
      value = '/' if value.blank?
      value.start_with?('/') ? value : "/#{value}"
    end

    def ttl
      configured = Integer(ENV.fetch('TELEPHONY_JANUS_WS_TICKET_TTL_SECONDS', DEFAULT_TTL.to_i).to_s, 10)
      configured.clamp(MIN_TTL_SECONDS, MAX_TTL_SECONDS).seconds
    rescue ArgumentError
      DEFAULT_TTL
    end

    def secure_match?(left, right)
      left = left.to_s
      right = right.to_s
      return false if left.blank? || right.blank? || left.bytesize != right.bytesize

      ActiveSupport::SecurityUtils.secure_compare(left, right)
    end

    def verifier
      Rails.application.message_verifier(:telephony_janus_websocket)
    end
  end
end
