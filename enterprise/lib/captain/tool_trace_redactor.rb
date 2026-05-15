# frozen_string_literal: true

class Captain::ToolTraceRedactor
  SENSITIVE_KEY_PATTERN = /
    (otp|token|secret|password|credential|authorization|process_?id|session|
     api_?key|access_?key|refresh|url|link|webhook|metadata|source_?text|content|artifact|
     auth_?config|template|param_?schema|fixed_?value)
  /ix
  SENSITIVE_VALUE_PATTERN = %r{
    https?://|
    bearer\s+|
    authorization\s*[:=]|
    (?:token|api[_\s-]?key|secret|password|credential|session|webhook|artifact|source[_\s-]?text|content)\s*[:=]?
  }ix

  class << self
    def call(value)
      new.call(value)
    end
  end

  def call(value)
    case value
    when Hash
      redact_hash(value)
    when Array
      value.map { |item| call(item) }
    when String
      sensitive_string?(value) ? '[FILTERED]' : value
    else
      value
    end
  end

  private

  def redact_hash(value)
    value.each_with_object({}) do |(key, item), result|
      result[key] = sensitive_key?(key) ? '[FILTERED]' : call(item)
    end
  end

  def sensitive_key?(key)
    key.to_s.match?(SENSITIVE_KEY_PATTERN)
  end

  def sensitive_string?(value)
    value.match?(SENSITIVE_VALUE_PATTERN)
  end
end
