# frozen_string_literal: true

# Deleting an account from the super admin is NEVER immediate: the account is marked for deletion and removed by the
# daily Internal::DeleteAccountsJob when the grace period is over, so a mistake (or a stolen session) can still be taken
# back. The mark is the one the operator app uses (custom_attributes `marked_for_deletion_at` and
# `marked_for_deletion_reason`), so the status «На удалении» and the job work for it as they do for any account.
#
#   deletion = SuperAdmin::AccountDeletion.new(account: account, actor: current_super_admin, request: request)
#   deletion.schedule   # => :scheduled, or :already_scheduled (the date does not move)
#   deletion.deletion_at # => 2026-10-26 14:30 +05:00
#   deletion.cancel     # => :cancelled, or :not_scheduled
#
# Both leave an entry in the audit log of the account. Nobody is told by e-mail: the e-mail the operator app sends for a
# deletion asks the account owner to confirm a deletion HE requested, which this is not.
class SuperAdmin::AccountDeletion
  GRACE_PERIOD = 7.days
  REASON = 'manual_deletion'
  AT_KEY = 'marked_for_deletion_at'
  REASON_KEY = 'marked_for_deletion_reason'

  attr_reader :account

  def initialize(account:, actor: nil, request: nil)
    @account = account
    @actor = actor
    @request = request
  end

  def scheduled?
    deletion_at.present?
  end

  # When the job will delete the account (Time); nil when no deletion is scheduled
  def deletion_at
    raw = account.custom_attributes.to_h[AT_KEY]
    Time.zone.parse(raw.to_s) if raw.present?
  rescue ArgumentError
    nil
  end

  def schedule
    outcome = :already_scheduled
    account.with_lock do
      next if scheduled?

      moment = GRACE_PERIOD.from_now.iso8601
      account.update!(custom_attributes: account.custom_attributes.to_h.merge(AT_KEY => moment, REASON_KEY => REASON))
      audit('schedule_deletion', 'name' => account.name, 'deletion_at' => moment, 'grace_days' => GRACE_PERIOD.in_days.to_i)
      outcome = :scheduled
    end
    outcome
  end

  def cancel
    outcome = :not_scheduled
    account.with_lock do
      next unless scheduled?

      planned = account.custom_attributes[AT_KEY]
      account.update!(custom_attributes: account.custom_attributes.to_h.except(AT_KEY, REASON_KEY))
      audit('cancel_deletion', 'name' => account.name, 'was_scheduled_for' => planned)
      outcome = :cancelled
    end
    outcome
  end

  private

  def audit(action, changes)
    SuperAdmin::AccountAudit.record(account: account, actor: @actor, action: action, changes: changes, request: @request)
  end
end
