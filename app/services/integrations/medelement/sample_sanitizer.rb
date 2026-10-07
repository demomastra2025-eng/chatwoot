class Integrations::Medelement::SampleSanitizer
  SECRET_KEY = /token|secret|password|authorization|api.?key|integrator.?key|credential|cookie|bearer|private.?key/i
  IDENTIFIER_KEY = /(?:code|_id|Id|iin|phone|email|address|patient|name|comment)/i
  CABINET_CODE_KEY = /cabinet.*code|code.*cabinet/i
  ENUM_KEY = /working|published|flag|type|status|active|enabled|removed|kind|state|duration|receptionTime/i
  TIME_KEY = /\A(?:start|end|date|from|to|begin|finish)(?:Time|Datetime|Date|At)?\z/i
  TIME_VALUE = /\A(?:
    \d{1,2}:\d{2}(?::\d{2})? |
    \d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2})?(?:Z|[+-]\d{2}:?\d{2})?)? |
    \d{2}\.\d{2}\.\d{4}(?:\ \d{2}:\d{2}(?::\d{2})?)?
  )\z/x
  TOKEN_VALUE = /\A(?:bearer\s+\S+|(?:sk|pk|eyJ)[_-]\S+|[A-Za-z0-9_-]{24,}|\S+@\S+|\+?\d[\d\s().-]{6,}\d)\z/i

  def sanitize(value, key: nil)
    case value
    when Hash
      sanitize_hash(value)
    when Array
      value.map { |child| sanitize(child, key: key) }
    when String
      sanitize_string(value, key)
    when Numeric
      key.to_s.match?(IDENTIFIER_KEY) ? placeholder(value) : value
    else
      value
    end
  end

  def digest(value)
    "<hash:#{Integrations::Medelement::ErrorSanitizer.digest(value)[0, 10]}>"
  end

  private

  def sanitize_hash(value)
    value.each_with_object({}) do |(field, child), result|
      field = field.to_s
      next if field.match?(SECRET_KEY) || field.match?(TOKEN_VALUE)

      result[field] = sanitize(child, key: field)
    end
  end

  def sanitize_string(value, key)
    return digest(value) if key.to_s.match?(CABINET_CODE_KEY)
    return placeholder(value) if value.match?(TOKEN_VALUE) || key.to_s.match?(IDENTIFIER_KEY)
    return value if safe_time?(value, key) || safe_enum?(value, key)

    placeholder(value)
  end

  def safe_time?(value, key)
    key.to_s.match?(TIME_KEY) && value.match?(TIME_VALUE)
  end

  def safe_enum?(value, key)
    key.to_s.match?(ENUM_KEY) && value.match?(/\A[a-z][a-z0-9_-]{0,31}\z/i)
  end

  def placeholder(value)
    "<#{value.is_a?(Numeric) ? 'number' : 'string'}:#{value.to_s.length}>"
  end
end
