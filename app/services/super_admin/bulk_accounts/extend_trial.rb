# frozen_string_literal: true

# Extends the trial of the accounts by the usual number of days (Accounts::Plans.trial_days), the same as «Продлить» on the
# card. Only a trial that was started from the admin panel can be extended (it has a snapshot of what it granted); an
# account on no trial, or on a trial of another kind, is skipped. A trial that has ended is opened again.
class SuperAdmin::BulkAccounts::ExtendTrial < SuperAdmin::BulkAccounts::Base
  def days = ::Accounts::Plans.trial_days

  def evaluate(account)
    return skip(account, :not_trial) unless account.trial? && account.trial_snapshot?

    expires_at = account.trial_expires_at
    running = expires_at.present? && expires_at > Time.current
    change(account, from: expires_at, to: (running ? expires_at : Time.current) + days.days, ended: !running)
  end

  def perform(account)
    account.extend_trial!(days)
    audit(account, 'extend_trial', 'trial_expires_at' => account.custom_attributes['trial_expires_at'])
    nil
  end
end
