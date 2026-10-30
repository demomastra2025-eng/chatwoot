# frozen_string_literal: true

class OwnerFinance::AccessPolicy
  DEFAULT_OWNER_USER_ID = 6
  DEFAULT_WORKSPACE_ACCOUNT_ID = 48

  def self.owner_user_id
    ENV.fetch('OWNER_FINANCE_USER_ID', DEFAULT_OWNER_USER_ID.to_s).to_i
  end

  def self.workspace_account_id
    ENV.fetch('OWNER_FINANCE_WORKSPACE_ACCOUNT_ID', DEFAULT_WORKSPACE_ACCOUNT_ID.to_s).to_i
  end

  def self.allowed?(user, impersonation_context: nil)
    return false if user.blank?
    return false if impersonation_context.present?

    target_id = owner_user_id
    target_id.positive? && user.id.to_i == target_id
  end
end
