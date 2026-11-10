# frozen_string_literal: true

require 'openssl'
require 'base64'

class Whatsapp::Flows::TokenService # rubocop:disable Metrics/ClassLength
  TOKEN_PREFIX = 'olf1'
  GRANT_PREFIX = 'olfg1'
  DEFAULT_TTL = 7.days
  GRANT_TTL = 1.hour
  KEY_DERIVATION_SALT = 'whatsapp_flows_token_hmac_v1'
  ENDPOINT_TOKEN_FORMAT = /\Ach_(\d+)_([A-Za-z0-9_-]{16,96})\z/
  PREVIEW_PREFIXES = %w[flows-builder preview_].freeze

  class << self
    def generate_endpoint_secret
      SecureRandom.urlsafe_base64(24)
    end

    def build_endpoint_token(channel, secret = nil)
      resolved_secret = secret.presence || channel&.provider_config.to_h.dig('whatsapp_flows', 'endpoint_secret')
      return nil if channel&.id.blank? || resolved_secret.blank?

      "ch_#{channel.id}_#{resolved_secret}"
    end

    def resolve_channel_by_endpoint_token(endpoint_token)
      match = ENDPOINT_TOKEN_FORMAT.match(endpoint_token.to_s.strip)
      return nil unless match

      channel_id = match[1].to_i
      provided_secret = match[2]
      channel = Channel::Whatsapp.find_by(id: channel_id, provider: 'whatsapp_cloud')
      return nil unless channel

      stored_secret = channel.provider_config.to_h.dig('whatsapp_flows', 'endpoint_secret').to_s
      return nil if stored_secret.blank? || stored_secret.bytesize != provided_secret.bytesize
      return nil unless ActiveSupport::SecurityUtils.secure_compare(stored_secret, provided_secret)

      channel
    end

    # rubocop:disable Metrics/ParameterLists
    def generate_flow_token(
      channel:,
      kind: 'booking',
      conversation_id: nil,
      contact_id: nil,
      locale: nil,
      metadata: nil,
      ttl: DEFAULT_TTL
    )
      claims = {
        v: 1,
        cid: channel.id,
        aid: channel.account_id,
        k: kind.to_s,
        cv: conversation_id,
        ct: contact_id,
        l: locale.presence&.to_s,
        m: metadata.presence,
        exp: (Time.current + ttl).to_i,
        n: SecureRandom.urlsafe_base64(6)
      }.compact

      encode_signed_token(TOKEN_PREFIX, claims)
    end

    def generate_booking_grant(
      channel:,
      resource_id:,
      starts_at:,
      duration_min:,
      service_id: nil,
      conversation_id: nil,
      contact_id: nil,
      cabinet_code: nil,
      client_attrs: nil,
      ttl: GRANT_TTL
    )
      parsed_start = starts_at.is_a?(Time) ? starts_at : Time.iso8601(starts_at.to_s)
      claims = {
        v: 1,
        cid: channel.id,
        aid: channel.account_id,
        cv: conversation_id,
        ct: contact_id,
        rid: resource_id.to_i,
        sid: service_id&.to_i,
        st: parsed_start.iso8601,
        dur: duration_min.to_i,
        cab: cabinet_code.to_s.strip.presence,
        ca: encrypt_grant_client_attrs(client_attrs),
        exp: (Time.current + ttl).to_i,
        n: SecureRandom.urlsafe_base64(6)
      }.compact

      encode_signed_token(GRANT_PREFIX, claims)
    end
    # rubocop:enable Metrics/ParameterLists

    def verify_flow_token(raw_token, channel:)
      token = raw_token.to_s.strip
      return preview_result if unsigned_preview_token?(token)

      claims = verify_signed_claims(token, TOKEN_PREFIX)
      return claims if claims[:valid] == false

      validate_claims(claims[:claims], channel)
    end

    def verify_booking_grant(raw_grant, channel:)
      token = raw_grant.to_s.strip
      verified = verify_signed_claims(token, GRANT_PREFIX)
      return verified if verified[:valid] == false

      validate_grant_claims(verified[:claims], channel)
    end

    private

    def encode_signed_token(prefix, claims)
      encoded_claims = Base64.urlsafe_encode64(claims.to_json, padding: false)
      signature = sign_segment("#{prefix}.#{encoded_claims}")
      "#{prefix}.#{encoded_claims}.#{signature}"
    end

    def verify_signed_claims(token, expected_prefix)
      return invalid_result(:malformed_token) unless signed_token_format?(token, expected_prefix)

      prefix, encoded_claims, provided_sig = token.split('.', 3)
      expected_sig = sign_segment("#{prefix}.#{encoded_claims}")
      unless provided_sig.bytesize == expected_sig.bytesize &&
             ActiveSupport::SecurityUtils.secure_compare(expected_sig, provided_sig)
        return invalid_result(:invalid_signature)
      end

      claims = parse_claims(encoded_claims)
      claims ? { valid: true, claims: claims } : invalid_result(:malformed_claims)
    end

    def unsigned_preview_token?(token)
      return true if token.blank? || token == 'unused'

      PREVIEW_PREFIXES.any? { |prefix| token.start_with?(prefix) }
    end

    def signed_token_format?(token, expected_prefix)
      parts = token.split('.', 3)
      parts.length == 3 && parts[0] == expected_prefix && parts[1].present? && parts[2].present?
    end

    def parse_claims(encoded_claims)
      decoded = Base64.urlsafe_decode64(encoded_claims)
      parsed = JSON.parse(decoded)
      parsed.is_a?(Hash) ? parsed.with_indifferent_access : nil
    rescue ArgumentError, JSON::ParserError
      nil
    end

    def validate_claims(claims, channel)
      return invalid_result(:channel_mismatch) unless matching_channel?(claims, channel)
      return invalid_result(:expired_token) if claims[:exp].to_i < Time.current.to_i

      { valid: true, preview: false, payload: extract_verified_payload(claims) }
    end

    def validate_grant_claims(claims, channel)
      return invalid_result(:channel_mismatch) unless matching_channel?(claims, channel)
      return invalid_result(:expired_grant) if claims[:exp].to_i < Time.current.to_i
      return invalid_result(:malformed_claims) if claims[:rid].to_i <= 0 || claims[:dur].to_i <= 0 || claims[:st].blank?

      { valid: true, payload: extract_verified_grant_payload(claims) }
    end

    def matching_channel?(claims, channel)
      channel.present? && claims[:cid].to_i == channel.id && claims[:aid].to_i == channel.account_id
    end

    def extract_verified_payload(claims)
      raw_meta = claims[:m]
      {
        channel_id: claims[:cid].to_i,
        account_id: claims[:aid].to_i,
        kind: claims[:k].to_s.presence || 'booking',
        conversation_id: claims[:cv],
        contact_id: claims[:ct],
        locale: claims[:l],
        metadata: raw_meta.is_a?(Hash) ? raw_meta.with_indifferent_access : {}
      }
    end

    def extract_verified_grant_payload(claims)
      {
        channel_id: claims[:cid].to_i,
        account_id: claims[:aid].to_i,
        conversation_id: claims[:cv],
        contact_id: claims[:ct],
        resource_id: claims[:rid].to_i,
        service_id: claims[:sid].present? ? claims[:sid].to_i : nil,
        starts_at: claims[:st].to_s,
        duration_min: claims[:dur].to_i,
        cabinet_code: claims[:cab].presence,
        client_attrs: decrypt_grant_client_attrs(claims[:ca])
      }
    end

    def encrypt_grant_client_attrs(client_attrs)
      return nil if client_attrs.blank?

      grant_encryptor.encrypt_and_sign(client_attrs.to_h.to_json)
    end

    def decrypt_grant_client_attrs(encrypted_blob)
      return {} if encrypted_blob.blank?

      parsed = JSON.parse(grant_encryptor.decrypt_and_verify(encrypted_blob.to_s))
      parsed.is_a?(Hash) ? parsed.with_indifferent_access : {}
    rescue StandardError
      {}
    end

    def grant_encryptor
      ActiveSupport::MessageEncryptor.new(signing_key, cipher: 'aes-256-gcm')
    end

    def preview_result
      { valid: false, preview: true, reason: :unsigned_or_preview, payload: {} }
    end

    def invalid_result(reason)
      { valid: false, preview: false, reason: reason, payload: {} }
    end

    def sign_segment(signing_input)
      digest = OpenSSL::HMAC.digest('SHA256', signing_key, signing_input)
      Base64.urlsafe_encode64(digest, padding: false)
    end

    def signing_key
      ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base)
                                 .generate_key(KEY_DERIVATION_SALT, 32)
    end
  end
end
