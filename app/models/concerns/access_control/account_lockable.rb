module AccessControl::AccountLockable
  extend ActiveSupport::Concern

  private

  def lock_account_for_access_control
    return unless account&.persisted?

    locked_account = account.class.lock.find(account.id)
    account.assign_attributes(
      access_control_mode: locked_account.access_control_mode,
      access_role_canonicalized_at: locked_account.access_role_canonicalized_at
    )
    account.clear_attribute_changes(%w[access_control_mode access_role_canonicalized_at])
  end
end
