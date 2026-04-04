# frozen_string_literal: true

module Captain::Runtime::HashNormalizer
  module_function

  def normalize(hash, label: 'hash', freeze_result: false)
    return {} if hash.blank?

    unless hash.respond_to?(:to_h)
      raise ArgumentError, "#{label} must be a hash-like object"
    end

    normalized = hash.to_h.deep_symbolize_keys
    freeze_result ? normalized.freeze : normalized
  end

  def merge(*hashes)
    hashes.compact.reduce({}) do |merged, hash|
      merged.merge(normalize(hash))
    end
  end
end
