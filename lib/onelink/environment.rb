# frozen_string_literal: true

module Onelink::Environment
  PREFIXES = {
    'LEGACY_CHATWOOT_' => 'ONELINK_LEGACY_',
    'CHATWOOT_' => 'ONELINK_',
    'CRAFTY_' => 'ONELINK_'
  }.freeze

  module_function

  def canonical_key(key)
    name = key.to_s
    prefix = PREFIXES.keys.find { |candidate| name.start_with?(candidate) }
    prefix ? name.sub(prefix, PREFIXES.fetch(prefix)) : name
  end

  # Presence matters: an explicitly empty canonical value must not reactivate a
  # legacy endpoint/credential. Stored installation-config identities stay intact.
  def fetch(key, default_value = nil, aliases: [])
    keys = [canonical_key(key), key.to_s, *aliases].uniq
    selected = keys.find { |name| ENV.key?(name) }
    selected ? ENV.fetch(selected) : default_value
  end
end
