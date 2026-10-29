# frozen_string_literal: true

module Onelink::Mcp::ResponseRedactor
  FILTERED = '[FILTERED]'
  MAX_DEPTH = 12
  SECRET_KEY_PATTERN = /
    \A(?:
      (?:.*[_-])?(?:
        token|secret|secret_key|password|passwd|passphrase|otp|otp_code|pin_code|
        verification_pin|pairing_code|backup_code|otp_backup_codes|api_key|api_hash|
        access_key|private_key|encryption_key|client_secret|webhook_secret|
        string_session|pending_phone_code_hash|janus_ticket
      )|
      pairingCode|authorization|credentials|auth_config
    )\z
  /ix
  INLINE_SECRET_VALUE_PATTERN = %r{
    \b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}|
    \b(?:sk|rk|pk)-[A-Za-z0-9_-]{12,}|
    https?://[^\s"']*(?:[?&](?:token|access_token|api_key|secret|password|signature)=[^\s&"']+)|
    \b(?:authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|webhook[_-]?secret|password)\s*[:=]\s*\S+
  }ix

  module_function

  def call(value, depth: 0)
    return FILTERED if depth > MAX_DEPTH

    case value
    when Hash
      redact_hash(value, depth: depth)
    when Array
      value.map { |entry| call(entry, depth: depth + 1) }
    when String
      redact_string(value, depth: depth)
    else
      value
    end
  end

  def redact_hash(hash, depth:)
    hash.each_with_object({}) do |(key, entry), output|
      normalized_key = key.is_a?(Symbol) ? key : key.to_s
      output[normalized_key] = secret_key?(key) ? FILTERED : call(entry, depth: depth + 1)
    end
  end

  def redact_string(value, depth:)
    trimmed = value.lstrip
    if trimmed.start_with?('{', '[') && depth < MAX_DEPTH
      parsed = parse_json_structure(value)
      return JSON.pretty_generate(call(parsed, depth: depth + 1)) unless parsed.nil?
    end

    value.gsub(INLINE_SECRET_VALUE_PATTERN, FILTERED)
  end

  def parse_json_structure(value)
    parsed = JSON.parse(value)
    parsed if parsed.is_a?(Hash) || parsed.is_a?(Array)
  rescue JSON::ParserError, TypeError
    nil
  end

  def secret_key?(key)
    key.to_s.strip.match?(SECRET_KEY_PATTERN)
  end
end
