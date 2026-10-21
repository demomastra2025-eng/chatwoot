# frozen_string_literal: true

# «Обновить лимиты по тарифу»: writes the numbers of the plan as it is now into the limits of an account that follow the plan, and
# touches nothing else.
#
#   sync = Accounts::SyncPlanLimits.new(account: account, actor: current_super_admin)
#   sync.preview # what would change, nothing is written
#   sync.call    # writes it under a row lock and leaves an entry in the audit log
#
# The plan of the account is the one it has: the base and the modules applied to it (the numbers of config/account_plans.yml are read
# now, so a number that was changed in the file since the plan was applied is the one written). What it does and does not do:
#
# * a limit that follows the plan («Как в тарифе») and has a number in the plan gets that number;
# * a limit chosen for this account («Своё число», «Без ограничений», see Accounts::LimitSettings) stays as it is;
# * a limit the plan has no number for stays as it is;
# * a limit that the end of a trial holds at 0 stays at 0: the number comes back when the plan is applied («Применить тариф», which
#   gives back what a trial took), not here;
# * the functions, the modules, the fine tuning and the plan attributes are never touched; an account without a plan has nothing to
#   follow and nothing is written for it.
#
# The numbers the plan wrote are kept beside the list of the limits chosen by hand, exactly as «Применить тариф» keeps them, so a
# number of the plan that changes again is still told from a number somebody typed.
class Accounts::SyncPlanLimits
  AUDIT_ACTION = 'sync_plan_limits'

  # plan_assigned: whether the account has a plan to follow
  # limits       : the numbers written, { 'conversations' => { 'from' => 500, 'to' => 1000 } } ('from' nil: the limit held no number)
  # before       : the number that applied before to each of these limits, { 'conversations' => 500 } (nil: no limit), which is what
  #                the screens say ('from' is what was stored: without a number the general value of the platform applied)
  # kept         : the limits chosen for this account whose number differs from the plan's (they stay)
  # held         : the limits an ended trial holds at 0 (they stay until the plan is applied)
  Diff = Struct.new(:plan_assigned, :limits, :before, :kept, :held, keyword_init: true) do
    def changed?
      limits.any?
    end

    def as_json(*)
      { 'plan_assigned' => plan_assigned, 'limits' => limits, 'kept_limits' => kept, 'held_limits' => held, 'changed' => changed? }
    end
  end

  attr_reader :account

  def initialize(account:, actor: nil, request: nil)
    @account = account
    @actor = actor
    @request = request
    @audit_extra = {}
  end

  # More keys for the entry of the audit log (a bulk action marks its entries with `'bulk' => true`). Returns the service.
  def with_audit_extra(extra)
    @audit_extra = extra
    self
  end

  # No writes at all
  def preview
    build_diff
  end

  # The account is read again under its lock, so what is written is what the account holds now, not what a page showed earlier
  def call
    diff = nil
    account.with_lock do
      diff = build_diff
      write if diff.changed?
    end
    record_audit(diff) if diff.changed?
    diff
  end

  private

  def build_diff
    settings = Accounts::LimitSettings.new(account)
    @result = settings.follow_current_plan
    current = account.limits.to_h
    Diff.new(
      plan_assigned: account.custom_attributes.to_h[Accounts::ApplyPlan::PLAN_KEY].present?,
      limits: @result.changes.keys.index_with { |key| { 'from' => current[key], 'to' => @result.limits[key] } },
      before: @result.changes.transform_values { |change| change['from'].value },
      kept: settings.kept_keys, held: settings.held_limit_keys
    )
  end

  def write
    account.limits = @result.limits
    account.custom_attributes = @result.custom_attributes(account.custom_attributes)
    account.save!
  end

  def record_audit(diff)
    changes = { 'limits' => diff.limits }.merge(@audit_extra)
    SuperAdmin::AccountAudit.record(account: account, actor: @actor, action: AUDIT_ACTION, changes: changes, request: @request)
  end
end
