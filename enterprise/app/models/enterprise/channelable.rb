module Enterprise::Channelable
  extend ActiveSupport::Concern

  WHATSAPP_WEB_RUNTIME_AUDIT_FIELDS = %w[
    connection_state
    lifecycle_state
    last_error
    last_synced_at
    qr_code
    sync_state
  ].freeze

  # The tokens a Weixin channel receives at runtime and its runtime snapshot. Its credentials (ilink_token, webhook_secret)
  # stay in the entry as "[FILTERED]" (AuditLogs::SecretFilter).
  WEIXIN_SENSITIVE_AUDIT_FIELDS = %w[
    context_token
    context_tokens
    last_error
    runtime_state
    token_fingerprint
  ].freeze

  # The state of the Telegram session the gateway reports all day. The runtime snapshot (runtime_state) keeps only the
  # operator's settings and the session string, the API hash and the webhook secret are written as "[FILTERED]".
  TELEGRAM_PERSONAL_RUNTIME_AUDIT_FIELDS = %w[
    connection_state
    lifecycle_state
    last_error
    last_synced_at
  ].freeze

  # Active support concern has `included` which changes the order of the method lookup chain
  # https://stackoverflow.com/q/40061982/3824876
  # manually prepend the instance methods to combat this
  included do
    prepend InstanceMethods
  end

  module InstanceMethods
    def create_audit_log_entry
      account = self.account
      associated_type = 'Account'

      return if inbox.nil?

      auditable_id = inbox.id
      auditable_type = 'Inbox'
      audited_changes = filtered_audited_changes

      return if audited_changes.blank?

      # skip audit log creation if the only change is whatsapp channel template update
      return if messaging_template_updates?(audited_changes)

      Enterprise::AuditLog.create(
        auditable_id: auditable_id,
        auditable_type: auditable_type,
        action: 'update',
        associated_id: account.id,
        associated_type: associated_type,
        audited_changes: audited_changes
      )
    end

    def messaging_template_updates?(changes)
      # if there is more than one key, return false
      return false unless changes.keys.length == 1

      # if the only key is message_templates_last_updated, return true
      changes.key?('message_templates_last_updated')
    end

    def filtered_audited_changes
      changes = saved_changes.to_h.except('updated_at', *runtime_audit_fields)
      keep_runtime_settings_only!(changes)

      AuditLogs::SecretFilter.filter(changes)
    end

    # A change of the runtime snapshot is written only when the operator's own settings changed, and only those settings
    def keep_runtime_settings_only!(changes)
      key = AuditLogs::SecretFilter::RUNTIME_STATE
      return unless changes.key?(key)

      settings = AuditLogs::SecretFilter.runtime_settings_change(changes.delete(key))
      changes[key] = settings if settings
    end

    def runtime_audit_fields
      case self
      when ::Channel::WhatsappWeb then WHATSAPP_WEB_RUNTIME_AUDIT_FIELDS
      when ::Channel::Weixin then WEIXIN_SENSITIVE_AUDIT_FIELDS
      when ::Channel::TelegramPersonal then TELEGRAM_PERSONAL_RUNTIME_AUDIT_FIELDS
      else []
      end
    end
  end
end
