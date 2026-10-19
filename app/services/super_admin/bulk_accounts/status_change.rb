# frozen_string_literal: true

# The common part of blocking and unblocking: the status of the account moves from one value to the other. An account that
# is already there is skipped. The entry of the audit log says from what to what.
class SuperAdmin::BulkAccounts::StatusChange < SuperAdmin::BulkAccounts::Base
  def evaluate(account)
    return skip(account, already_reason) if account.status == target_status

    change(account, from: account.status, to: target_status)
  end

  def perform(account)
    moved = false
    account.with_lock do
      next if account.status == target_status

      account.update!(status: target_status)
      moved = true
    end
    return already_reason unless moved

    audit(account, audit_action, 'status' => [source_status, target_status])
    nil
  end

  private

  def source_status = target_status == 'suspended' ? 'active' : 'suspended'
end
