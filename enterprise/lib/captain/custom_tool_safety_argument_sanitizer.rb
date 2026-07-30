# frozen_string_literal: true

class Captain::CustomToolSafetyArgumentSanitizer
  FILTERED_VALUE = 'x'
  AUTH_CONFIG_KEY = :auth_config_json
  STRING_CONFIG_KEYS = %i[
    endpoint_url request_template response_template param_schema_json
  ].freeze

  QUERY_SECRET = /((?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|authorization|credential)=)[^&\s"']+/i
  JSON_SECRET_KEYS = 'api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|' \
                     'authorization|credential|fixed[_-]?value'
  JSON_SECRET = /("(?:#{JSON_SECRET_KEYS})"\s*:\s*")[^"]*(")/i
  LABELED_SECRET = /((?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|authorization|credential)\s*[:=]\s*)[^\s,}"']+/i
  BEARER_SECRET = /(Bearer\s+)[^\s,"']+/i

  class << self
    def call(arguments)
      new.call(arguments)
    end
  end

  def call(arguments)
    arguments.each_with_object({}) do |(key, value), sanitized|
      sanitized[key] = sanitize_argument(key.to_sym, value)
    end
  end

  private

  def sanitize_argument(key, value)
    return sanitize_auth_config(value) if key == AUTH_CONFIG_KEY
    return sanitize_string(value) if STRING_CONFIG_KEYS.include?(key)

    value
  end

  def sanitize_auth_config(value)
    parsed = JSON.parse(value.to_s)
    JSON.generate(redact_auth_value(parsed))
  rescue JSON::ParserError
    sanitize_string(value)
  end

  def redact_auth_value(value)
    case value
    when Hash
      value.transform_values { |item| redact_auth_value(item) }
    when Array
      value.map { |item| redact_auth_value(item) }
    when nil, true, false
      value
    else
      FILTERED_VALUE
    end
  end

  def sanitize_string(value)
    return value unless value.is_a?(String)

    value.gsub(QUERY_SECRET, "\\1#{FILTERED_VALUE}")
         .gsub(JSON_SECRET, "\\1#{FILTERED_VALUE}\\2")
         .gsub(LABELED_SECRET, "\\1#{FILTERED_VALUE}")
         .gsub(BEARER_SECRET, "\\1#{FILTERED_VALUE}")
  end
end
