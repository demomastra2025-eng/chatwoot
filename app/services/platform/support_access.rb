# frozen_string_literal: true

# The impersonation value must come from the current request's verified server
# context, never from request parameters or a browser-supplied role flag.
module Platform::SupportAccess
  def self.allowed?(user:, impersonation: nil)
    return user.active_for_authentication? if user.is_a?(SuperAdmin)

    impersonation.is_a?(Hash) &&
      impersonation['type'] == 'super_admin_impersonation' && impersonation['actor_id'].present?
  end
end
