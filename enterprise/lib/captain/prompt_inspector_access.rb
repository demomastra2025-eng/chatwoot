# frozen_string_literal: true

# Who may read the compiled prompt of an agent (Captain::Assistant::PromptPreviewService):
# the platform team only. A clinic, that is an account user of any role, never sees or
# writes AI prompts; the platform team configures them.
#
# The platform team here is
# - a super admin signed in to the dashboard as himself (a member of the account), or
# - a super admin inside a clinic through «Войти как»: the impersonation context that
#   SuperAdmin::ImpersonationService.context_for_request verified for this request
#   (an active super admin started it). It never comes from request parameters.
module Captain::PromptInspectorAccess
  IMPERSONATION_TYPE = 'super_admin_impersonation'

  def self.allowed?(user:, impersonation: nil)
    return true if user.is_a?(SuperAdmin)

    impersonation.is_a?(Hash) && impersonation['type'] == IMPERSONATION_TYPE && impersonation['actor_id'].present?
  end
end
