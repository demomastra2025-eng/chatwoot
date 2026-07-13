# frozen_string_literal: true

class Meta::AuthorizationErrorClassifier
  TRANSIENT_CODES = [1, 2, 4, 17, 341].freeze
  TRANSIENT_HTTP_STATUSES = [408, 425, 429].freeze
  PERMISSION_CODE_RANGE = (200..299)
  CONFIRMED_INVALID_TOKEN_SUBCODES = [458, 459, 460, 463, 464, 467, 490].freeze

  Classification = Struct.new(:kind, :error, :confirmed, keyword_init: true) do
    def transient?
      kind == :transient
    end

    def action_required?
      %i[reauthorization_required permission_missing].include?(kind)
    end

    def confirmed_invalid?
      kind == :reauthorization_required && confirmed
    end
  end

  class << self
    def classify(payload = nil, http_status: nil, **keyword_payload)
      payload ||= keyword_payload
      error = normalize_error(payload)
      code = error['code'].to_i

      kind = if transient?(code, http_status)
               :transient
             elsif code == 190 || invalid_token_message?(error['message'])
               :reauthorization_required
             elsif code == 10 || PERMISSION_CODE_RANGE.cover?(code)
               :permission_missing
             else
               :unknown
             end

      Classification.new(kind: kind, error: safe_error(error), confirmed: confirmed_invalid?(error))
    end

    private

    def normalize_error(payload)
      parsed = if payload.respond_to?(:parsed_response)
                 payload.parsed_response
               elsif payload.respond_to?(:to_h)
                 payload.to_h
               else
                 {}
               end
      parsed = JSON.parse(parsed) if parsed.is_a?(String)
      parsed = parsed.to_h.with_indifferent_access
      (parsed[:error] || parsed).to_h.stringify_keys
    rescue JSON::ParserError, TypeError
      {}
    end

    def transient?(code, http_status)
      TRANSIENT_CODES.include?(code) || TRANSIENT_HTTP_STATUSES.include?(http_status.to_i) || http_status.to_i >= 500
    end

    def invalid_token_message?(message)
      message.to_s.match?(/access token|session has expired|session has been invalidated|validating access token/i)
    end

    def confirmed_invalid?(error)
      CONFIRMED_INVALID_TOKEN_SUBCODES.include?(error['error_subcode'].to_i) ||
        error['message'].to_s.match?(/session has expired|session has been invalidated/i)
    end

    def safe_error(error)
      {
        'code' => error['code'],
        'error_subcode' => error['error_subcode'],
        'type' => error['type'],
        'message' => error['message'].to_s.first(500),
        'fbtrace_id' => error['fbtrace_id']
      }.compact_blank
    end
  end
end
