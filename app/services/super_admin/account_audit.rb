# frozen_string_literal: true

# One entry of the audit log for an operator action on an account (impersonation, trial changes, plan changes).
# An action done by the platform itself (a new account getting the base plan) has no actor and is marked 'system'.
# Recording never raises: losing an audit row must not undo or block the action that was audited.
class SuperAdmin::AccountAudit
  SUPER_ADMIN_COMMENT = 'super_admin'
  SYSTEM_COMMENT = 'system'

  def self.record(account:, action:, actor: nil, changes: {}, request: nil)
    Audited::Audit.create!(
      auditable: account, associated: account, action: action, audited_changes: changes,
      user: actor, remote_address: request&.remote_ip, request_uuid: request&.request_id,
      comment: actor ? SUPER_ADMIN_COMMENT : SYSTEM_COMMENT
    )
  rescue StandardError => e
    Rails.logger.error("[SuperAdmin] Could not record audit '#{action}' for account #{account&.id}: #{e.class.name}: #{e.message}")
    nil
  end
end
