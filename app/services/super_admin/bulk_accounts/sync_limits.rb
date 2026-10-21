# frozen_string_literal: true

# «Обновить лимиты по тарифу» for the chosen accounts: the numbers of the plan as it is now go into the limits that follow it
# (Accounts::SyncPlanLimits), and nothing else changes - not the functions, the modules or the fine tuning. The limits chosen for an
# account by hand stay. It needs no setting: the confirmation page shows at once how many accounts and limits would change.
#
# An account without a plan has nothing to follow and is skipped (`:no_plan`); an account whose limits already are what the plan says
# is skipped too (`:limits_current`).
class SuperAdmin::BulkAccounts::SyncLimits < SuperAdmin::BulkAccounts::Base
  def evaluate(account)
    diff = sync_for(account).preview
    return skip(account, :no_plan, diff: diff) unless diff.plan_assigned
    return skip(account, :limits_current, diff: diff) unless diff.changed?

    change(account, diff: diff)
  end

  # nil when the limits were written; :limits_current when the account already was in step by the time its turn came
  def perform(account)
    diff = sync_for(account).call
    diff.changed? ? nil : :limits_current
  end

  private

  def sync_for(account)
    ::Accounts::SyncPlanLimits.new(account: account, actor: actor, request: request)
                              .with_audit_extra(SuperAdmin::BulkAccounts::AUDIT_EXTRA)
  end
end
