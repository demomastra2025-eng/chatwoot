module Enterprise::Channelable
  extend ActiveSupport::Concern

  # The columns the runtime of a channel rewrites all day (AuditLogs::SecretFilter::RUNTIME_COLUMNS) never reach its audit log;
  # its credentials are written as "[FILTERED]".

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

    # The same filter as the audit-log API and the redaction task: the runtime columns of the channel are left out, and a change
    # of the runtime snapshot is written only when the operator's own settings changed, and only those settings
    def filtered_audited_changes
      AuditLogs::SecretFilter.filter(saved_changes.to_h.except('updated_at'), channel_type: self.class.name)
    end
  end
end
