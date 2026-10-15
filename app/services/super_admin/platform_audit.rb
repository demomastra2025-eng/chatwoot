# frozen_string_literal: true

# One entry of the audit log for a super admin action on the platform itself (a setting of the installation, not of
# one clinic; for those see SuperAdmin::AccountAudit). Recording never raises: losing an audit row must not undo or
# block the action that was audited.
class SuperAdmin::PlatformAudit
  SUPER_ADMIN_COMMENT = 'super_admin'
  SYSTEM_COMMENT = 'system'

  def self.record(auditable:, action:, actor: nil, changes: {}, request: nil)
    Audited::Audit.create!(
      auditable: auditable, action: action, audited_changes: changes,
      user: actor, remote_address: request&.remote_ip, request_uuid: request&.request_id,
      comment: actor ? SUPER_ADMIN_COMMENT : SYSTEM_COMMENT
    )
  rescue StandardError => e
    Rails.logger.error("[SuperAdmin] Could not record audit '#{action}' for #{auditable.class.name} #{auditable&.id}: #{e.class.name}: #{e.message}")
    nil
  end
end
