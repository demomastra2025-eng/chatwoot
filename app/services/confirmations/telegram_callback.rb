# frozen_string_literal: true

require 'openssl'

class Confirmations::TelegramCallback
  PREFIX = 'cfm'
  SIGNATURE_LENGTH = 16
  DECISION_CODES = {
    'confirmed' => 'c',
    'declined' => 'd',
    'reschedule_requested' => 'r'
  }.freeze
  CODE_DECISIONS = DECISION_CODES.invert.freeze

  class << self
    def encode(confirmation_request, decision)
      decision_code = DECISION_CODES.fetch(decision.to_s)
      unsigned_value = [PREFIX, confirmation_request.id.to_s(36), decision_code].join(':')
      "#{unsigned_value}:#{signature(confirmation_request, unsigned_value)}"
    end

    def resolve(value:, account:, conversation:)
      prefix, encoded_id, decision_code, provided_signature = value.to_s.split(':', 4)
      return if prefix != PREFIX || CODE_DECISIONS.exclude?(decision_code) || provided_signature.blank?

      confirmation_request = account.confirmation_requests.find_by(id: parse_id(encoded_id), conversation: conversation)
      return if confirmation_request.blank?

      unsigned_value = [prefix, encoded_id, decision_code].join(':')
      expected_signature = signature(confirmation_request, unsigned_value)
      return unless ActiveSupport::SecurityUtils.secure_compare(provided_signature, expected_signature)

      { confirmation_request: confirmation_request, decision: CODE_DECISIONS.fetch(decision_code) }
    rescue ArgumentError
      nil
    end

    private

    def parse_id(value)
      Integer(value.to_s, 36)
    end

    def signature(confirmation_request, value)
      OpenSSL::HMAC.hexdigest('SHA256', confirmation_request.token, value).first(SIGNATURE_LENGTH)
    end
  end
end
