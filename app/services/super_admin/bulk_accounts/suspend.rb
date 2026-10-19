# frozen_string_literal: true

# Blocks the accounts (status «Заблокирован»): a blocked account does not serve its operators and its widgets until it is
# unblocked.
class SuperAdmin::BulkAccounts::Suspend < SuperAdmin::BulkAccounts::StatusChange
  def warning? = true

  private

  def target_status = 'suspended'
  def already_reason = :already_suspended
  def audit_action = 'suspend_account'
end
