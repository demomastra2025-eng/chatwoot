require 'digest/sha1'

module Crm
  module CodeNormalizer
    module_function

    def normalize(value)
      normalized = value.to_s.unicode_normalize(:nfkc).strip
      return '' if normalized.blank?

      parameterized = normalized.parameterize(separator: '_')
      return parameterized if parameterized.present?

      unicode_slug = normalized
                     .downcase
                     .gsub(/[^\p{Alnum}]+/u, '_')
                     .gsub(/\A_+|_+\z/, '').squeeze('_')
      return unicode_slug if unicode_slug.present?

      "code_#{Digest::SHA1.hexdigest(normalized).first(12)}"
    end
  end
end
