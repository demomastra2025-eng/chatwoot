# The secrets of the channels never reach the audit log, and never leave it.
#
# The update of a channel is written into the audit log of its inbox (Enterprise::Channelable), and account administrators read
# that log through the audit-log API. A credential column keeps its place in the entry, so the log still says that the token or
# the session was changed and by whom, but its value is written as "[FILTERED]" (a blank value stays blank: set and cleared are
# still told apart). Inside a JSON column (provider_config, additional_attributes) every key that names a credential is filtered
# the same way, also when the column keeps its JSON as a string. The runtime snapshot of a personal channel (runtime_state: QR
# login links, the dialog ids of a history import) keeps only the settings the operator sets himself (sync_groups,
# ignored_chat_ids). The columns the runtime of a channel rewrites all day (RUNTIME_COLUMNS: its connection, its last error, its
# sync clock) are left out when the type of the channel is known.
#
# The same filter runs when an entry is written (nothing secret is stored), when an entry of an inbox is read (the entries
# written before it) and in onelink:audits:redact_channel_secrets (the stored entries are cleaned in place). The inbox_created
# and inbox_updated account webhooks send the columns of the channel through it as well (Inbox::EventDataPresenter).
#
#   AuditLogs::SecretFilter.filter({ 'string_session' => [nil, '1BVts...'], 'name' => %w[a b] })
#   # => { 'string_session' => [nil, '[FILTERED]'], 'name' => ['a', 'b'] }
#   AuditLogs::SecretFilter.filter({ 'last_synced_at' => [nil, '2026-10-25'] }, channel_type: 'Channel::TelegramPersonal')
#   # => {}
class AuditLogs::SecretFilter
  FILTERED = '[FILTERED]'.freeze

  # The credential columns of the channels (Channel::*): spec/services/audit_logs/secret_filter_spec.rb checks that every
  # column of a channel that looks like a credential is either here or named in its list of public columns.
  SECRET_COLUMNS = %w[
    access_token
    api_hash
    auth_token
    bot_token
    confirmation_token
    context_token
    context_tokens
    csrf_token
    hmac_token
    ilink_token
    imap_password
    jsessionid
    li_at
    line_channel_secret
    line_channel_token
    page_access_token
    qr_code
    refresh_token
    secret
    smtp_password
    string_session
    twitter_access_token
    twitter_access_token_secret
    user_access_token
    webhook_secret
    x_li_track
  ].freeze

  # A key inside a JSON column that names a credential: tokens, secrets, passwords, API keys, sessions, the WhatsApp PIN.
  # A count of AI tokens (captain_tokens, max_tokens) is not a credential.
  SECRET_KEY_PATTERN = /
    token(?!s)|secret|password|passwd|api[_-]?key|api[_-]?hash|session|credential|private[_-]?key|cookie|csrf|
    \Aauthorization\z|(?:oauth|auth|authorization)[_-]?code|(?:\A|_)pin\z|\Ali_at\z
  /ix

  # The columns the runtime of a channel rewrites all day, which tell the administrator nothing about who changed the channel.
  # The Weixin tokens it receives at runtime and its runtime snapshot are left out with them; its credentials (ilink_token,
  # webhook_secret) stay in the entry as "[FILTERED]".
  RUNTIME_COLUMNS = {
    'Channel::WhatsappWeb' => %w[connection_state lifecycle_state last_error last_synced_at qr_code sync_state],
    'Channel::Weixin' => %w[context_token context_tokens last_error runtime_state token_fingerprint],
    'Channel::TelegramPersonal' => %w[connection_state lifecycle_state last_error last_synced_at]
  }.transform_values(&:freeze).freeze

  # The entries that carry the changes of a channel: Enterprise::Channelable writes them for its inbox
  CHANNEL_AUDITABLE_TYPES = %w[Inbox].freeze

  RUNTIME_STATE = 'runtime_state'.freeze
  RUNTIME_STATE_SETTINGS = %w[ignored_chat_ids sync_groups].freeze

  class << self
    # The changes of one entry ({ column => [before, after] } or { column => value }) with every secret filtered. A change of the
    # runtime snapshot that leaves the operator's settings as they were tells nothing, and is left out, as are the runtime
    # columns of the channel type (an inbox's channel_type, 'Channel::TelegramPersonal') when it is given.
    def filter(changes, channel_type: nil)
      return changes unless changes.is_a?(Hash)

      runtime_columns = runtime_columns(channel_type)
      changes.each_with_object({}) do |(key, value), filtered|
        next if runtime_columns.include?(key.to_s)

        value = filter_column(key.to_s, value)
        next if key.to_s == RUNTIME_STATE && unchanged_pair?(value)

        filtered[key] = value
      end
    end

    # The changes as the audits table gives them back: a JSON object, or the same object kept as a JSON string
    def filter_stored(changes, channel_type: nil)
      return filter(changes, channel_type: channel_type) if changes.is_a?(Hash)
      return changes unless changes.is_a?(String)

      parsed = parse_json(changes)
      parsed.is_a?(Hash) ? filter(parsed, channel_type: channel_type) : changes
    end

    # The changes of a stored entry as they may be shown: filtered for an entry of an inbox, as they are for the others. The
    # changes of an inbox that are not a JSON object (an array, a string that is not the JSON of an object) cannot be examined
    # and are shown as no changes at all.
    def filter_audit(audit)
      changes = audit.audited_changes
      return changes if changes.nil? || CHANNEL_AUDITABLE_TYPES.exclude?(audit.try(:auditable_type))

      filtered = filter_stored(changes, channel_type: audit_channel_type(audit))
      filtered.is_a?(Hash) ? filtered : {}
    end

    def secret_key?(key)
      SECRET_COLUMNS.include?(key.to_s) || key.to_s.match?(SECRET_KEY_PATTERN)
    end

    def runtime_columns(channel_type)
      RUNTIME_COLUMNS.fetch(channel_type.to_s, [])
    end

    private

    # The channel of the inbox the entry is about; nil once the inbox is deleted
    def audit_channel_type(audit)
      audit.try(:auditable).try(:channel_type)
    end

    def filter_column(key, value)
      return mask(value) if SECRET_COLUMNS.include?(key)
      return runtime_state(value) if key == RUNTIME_STATE

      deep_filter(value)
    end

    def deep_filter(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), filtered|
          filtered[key] = secret_key?(key) ? mask(item) : deep_filter(item)
        end
      when Array then value.map { |item| deep_filter(item) }
      when String then filter_json_string(value)
      else value
      end
    end

    # A JSON column kept as a string ('{"api_key":"..."}') is filtered as the object it holds and written back as a string. A
    # string with nothing to filter is given back as it was, so a filtered entry stays as it is.
    def filter_json_string(value)
      return value unless value.lstrip.start_with?('{', '[')

      parsed = parse_json(value)
      return value unless parsed.is_a?(Hash) || parsed.is_a?(Array)

      filtered = deep_filter(parsed)
      filtered == parsed ? value : JSON.generate(filtered)
    end

    # [before, after] or a list: each side on its own; one value: the value
    def mask(value)
      value.is_a?(Array) ? value.map { |side| mask_side(side) } : mask_side(value)
    end

    def mask_side(value)
      value.blank? ? value : FILTERED
    end

    def runtime_state(value)
      value.is_a?(Array) ? value.map { |side| runtime_state_side(side) } : runtime_state_side(value)
    end

    # A snapshot keeps the operator's settings (who turned group sync or an ignored chat on or off) and nothing else
    def runtime_state_side(side)
      return side if side.blank?
      return side.stringify_keys.slice(*RUNTIME_STATE_SETTINGS) if side.is_a?(Hash)

      FILTERED
    end

    def unchanged_pair?(value)
      value.is_a?(Array) && value.size == 2 && value.first == value.last
    end

    def parse_json(value)
      JSON.parse(value)
    rescue JSON::ParserError
      nil
    end
  end
end
