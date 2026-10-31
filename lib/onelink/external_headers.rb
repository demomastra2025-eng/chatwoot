# frozen_string_literal: true

module Onelink::ExternalHeaders
  PREFIX = 'X-OneLink-'
  LEGACY_PREFIX = 'X-Chatwoot-'

  module_function

  def with_legacy_aliases(headers)
    result = headers.dup
    return result unless legacy_aliases_enabled?

    headers.each do |name, value|
      next unless name.start_with?(PREFIX)

      result[name.sub(PREFIX, LEGACY_PREFIX)] = value
    end
    result
  end

  def legacy_aliases_enabled?
    %w[true 1 yes on].include?(ENV.fetch('ONELINK_LEGACY_EXTERNAL_HEADERS_ENABLED', 'true').to_s.strip.downcase)
  end
end
