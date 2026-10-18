# frozen_string_literal: true

# One entry of the audit log for an action on the platform itself (a setting of the installation, a user, a partner
# access, a sign-in of the super admin; for the actions on one account see SuperAdmin::AccountAudit). Recording never
# raises: losing an audit row must not undo or block the action that was audited.
#
# The actor is a super admin (comment 'super_admin'), a partner access of the Platform API (a PlatformApp, comment
# 'platform_app'), a name (a String: someone who is not a user of the platform, like an unknown e-mail typed into the
# sign-in) or nobody (a job or the platform itself); the last two are comment 'system'. A secret never goes into
# `changes`: the callers write the NAMES of what changed ('password' => 'changed'), not the values.
class SuperAdmin::PlatformAudit
  SUPER_ADMIN_COMMENT = 'super_admin'
  PARTNER_COMMENT = 'platform_app'
  SYSTEM_COMMENT = 'system'
  # The longest name of an unknown person kept in an entry (what was typed into the e-mail field of the sign-in)
  USERNAME_LIMIT = 120

  # Who did it, as the comment of the entry
  def self.comment_for(actor)
    case actor
    when nil, String then SYSTEM_COMMENT
    when PlatformApp then PARTNER_COMMENT
    else SUPER_ADMIN_COMMENT
    end
  end

  def self.record(auditable:, action:, actor: nil, changes: {}, request: nil)
    # A String is the name of someone unknown: `user=` of an audit keeps it in `username`
    actor = actor.truncate(USERNAME_LIMIT) if actor.is_a?(String)
    Audited::Audit.create!(
      auditable: auditable, action: action, audited_changes: changes, user: actor,
      remote_address: request&.remote_ip, request_uuid: request&.request_id, comment: comment_for(actor)
    )
  rescue StandardError => e
    Rails.logger.error("[SuperAdmin] Could not record audit '#{action}' for #{auditable.class.name} #{auditable&.id}: #{e.class.name}: #{e.message}")
    nil
  end
end
