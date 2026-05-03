# frozen_string_literal: true

module Captain::EncodingNormalizer
  REPLACEMENT_CHARACTER = '�'

  module_function

  def utf8(value)
    case value
    when String
      string(value)
    when Array
      value.map { |item| utf8(item) }
    when Hash
      value.each_with_object({}) do |(key, item), memo|
        memo[hash_key(key)] = utf8(item)
      end
    else
      value
    end
  end

  def string(value)
    return value unless value.is_a?(String)

    candidate = value.dup
    candidate.force_encoding(Encoding::UTF_8) if candidate.encoding == Encoding::ASCII_8BIT
    return candidate if candidate.encoding == Encoding::UTF_8 && candidate.valid_encoding?

    candidate.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: REPLACEMENT_CHARACTER)
  rescue Encoding::CompatibilityError, Encoding::ConverterNotFoundError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
    value.to_s.b.force_encoding(Encoding::UTF_8).encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: REPLACEMENT_CHARACTER)
  end

  def hash_key(key)
    key.is_a?(String) ? string(key) : key
  end
end
