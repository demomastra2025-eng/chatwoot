# The secrets of the channels never reach the audit log, and never leave it.
#
# The update of a channel is written into the audit log of its inbox (Enterprise::Channelable), and account administrators read
# that log through the audit-log API. A credential column keeps its place in the entry, so the log still says that the token or
# the session was changed and by whom, but its value is written as "[FILTERED]" (a blank value stays blank: set and cleared are
# still told apart). Inside a JSON column (provider_config, additional_attributes) every key that names a credential is filtered
# the same way. The runtime snapshot of a personal channel (runtime_state: QR login links, the dialog ids of a history import)
# keeps only the settings the operator sets himself (sync_groups, ignored_chat_ids).
#
# The same filter runs when an entry is written (nothing secret is stored), when an entry of an inbox is read (the entries
# written before it) and in onelink:audits:redact_channel_secrets (the stored entries are cleaned in place).
#
#   AuditLogs::SecretFilter.filter('string_session' => [nil, '1BVts...'], 'name' => %w[a b])
#   # => { 'string_session' => [nil, '[FILTERED]'], 'name' => ['a', 'b'] }
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

  # The entries that carry the changes of a channel: Enterprise::Channelable writes them for its inbox
  CHANNEL_AUDITABLE_TYPES = %w[Inbox].freeze

  RUNTIME_STATE = 'runtime_state'.freeze
  RUNTIME_STATE_SETTINGS = %w[ignored_chat_ids sync_groups].freeze

  class << self
    # The changes of one entry ({ column => [before, after] } or { column => value }) with every secret filtered
    def filter(changes)
      return changes unless changes.is_a?(Hash)

      changes.each_with_object({}) do |(key, value), filtered|
        filtered[key] = filter_column(key.to_s, value)
      end
    end

    # The changes as the audits table gives them back: a JSON object, or the same object kept as a JSON string
    def filter_stored(changes)
      return filter(changes) if changes.is_a?(Hash)
      return changes unless changes.is_a?(String)

      parsed = parse_json(changes)
      parsed.is_a?(Hash) ? filter(parsed) : changes
    end

    # The changes of a stored entry as they may be shown: filtered for an entry of an inbox, as they are for the others
    def filter_audit(audit)
      return audit.audited_changes unless CHANNEL_AUDITABLE_TYPES.include?(audit.try(:auditable_type))

      filter_stored(audit.audited_changes)
    end

    # Only the operator's settings out of a change of the runtime snapshot, nil when they did not change
    def runtime_settings_change(change)
      return unless change.is_a?(Array) && change.size == 2

      sides = change.map { |side| side.is_a?(Hash) ? side.stringify_keys.slice(*RUNTIME_STATE_SETTINGS) : side }
      sides.first == sides.last ? nil : sides
    end

    def secret_key?(key)
      SECRET_COLUMNS.include?(key.to_s) || key.to_s.match?(SECRET_KEY_PATTERN)
    end

    private

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
      else value
      end
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

    def runtime_state_side(side)
      return side if side.blank?
      return side if side.is_a?(Hash) && (side.keys.map(&:to_s) - RUNTIME_STATE_SETTINGS).empty?

      FILTERED
    end

    def parse_json(value)
      JSON.parse(value)
    rescue JSON::ParserError
      nil
    end
  end
end
