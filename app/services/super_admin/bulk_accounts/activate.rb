# frozen_string_literal: true

# Unblocks the accounts (status «Активен»).
class SuperAdmin::BulkAccounts::Activate < SuperAdmin::BulkAccounts::StatusChange
  private

  def target_status = 'active'
  def already_reason = :already_active
  def audit_action = 'activate_account'
end
