require 'digest'

# Negative, session-bound integers preserve the production JSON schemas while
# preventing a simulated ID from ever resolving to a positive database ID.
class Captain::Playground::SyntheticNamespace
  STRIDE = 4096
  ID_KEYS = /\A(?:id|display_id|.*_ids?)\z/

  def initialize(session_id)
    @base = (Digest::SHA256.hexdigest(session_id.to_s).first(10).to_i(16) + 1) * STRIDE
  end

  def encode(value, key: nil)
    transform(value, key: key, decode: false)
  end

  def decode(value, key: nil)
    transform(value, key: key, decode: true)
  end

  def synthetic?(value)
    case value
    when Hash then value.any? { |key, item| (id_key?(key) && negative_id?(item)) || synthetic?(item) }
    when Array then value.any? { |item| synthetic?(item) }
    else false
    end
  end

  private

  def transform(value, key:, decode:)
    case value
    when Hash
      value.to_h.transform_keys { |item| item }.each_with_object({}) do |(child_key, item), result|
        result[child_key] = transform(item, key: child_key, decode: decode)
      end
    when Array then value.map { |item| transform(item, key: key, decode: decode) }
    else
      if value.is_a?(String) && key.to_s.in?(%w[nearest last_past last_cancelled all])
        parsed = JSON.parse(value)
        return JSON.generate(transform(parsed, key: nil, decode: decode)) if parsed.is_a?(Hash) || parsed.is_a?(Array)
      end
      return value unless id_key?(key) && value.to_s.match?(/\A-?\d+\z/)

      integer = value.to_i
      return value if integer.zero?
      return encode_id(integer) unless decode
      return value unless integer.negative?

      local = -integer - @base
      raise ArgumentError, 'Synthetic reference belongs to another Playground session' unless local.between?(1, STRIDE - 1)

      local
    end
  rescue JSON::ParserError
    value
  end

  def encode_id(integer)
    return integer if integer.negative?
    raise ArgumentError, 'Synthetic reference exceeds its session namespace' unless integer < STRIDE

    -(@base + integer)
  end

  def id_key?(key)
    key.to_s.match?(ID_KEYS) && !%w[account_id user_id assistant_id sender_id].include?(key.to_s)
  end

  def negative_id?(value)
    Array(value).any? { |item| item.to_s.match?(/\A-\d+\z/) }
  end
end
