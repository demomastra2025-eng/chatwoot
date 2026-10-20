# frozen_string_literal: true

# Writes "base + chosen modules" into an account: the feature flags, the limits and the plan attributes.
#
#   service = Accounts::ApplyPlan.new(account: account, modules: %w[ai_agents], actor: current_super_admin)
#   service.preview # what would change, nothing is written
#   service.call    # writes it under a row lock and leaves an entry in the audit log
#
# What it sets:
# * flags   : switched on = base + the chosen modules + locked_on; switched off = the flags of the modules that are
#             not chosen and the never_enabled flags. Internal flags (and any flag no plan names) keep whatever the
#             account has, so a plan never changes an infrastructure switch.
# * limits  : numbers of the plan are written; keys the plan leaves null are not touched.
#             A limit chosen for this account (a number of its own or «без ограничений», see Accounts::LimitSettings) is left as it
#             is: the plan only writes the limits that follow it. Any number that is neither the number of the plan nor the number
#             this plan wrote last counts as chosen: one a super admin typed, one an account from before the plan holds, one a
#             partner wrote through the Platform API, one a new account was created with (the plan only fills the blanks). The
#             numbers written for the limits that follow the plan are kept (custom_attributes['limit_plan_numbers']), so a number of
#             the plan that changes later is still told from a number somebody typed.
#             The operator and channel limits that the end of a trial put at 0 are given back (the values from before the
#             trial, from the snapshot of the trial) without anybody asking: a plan is what the account pays for, so it must not
#             stay locked out; a number the plan itself sets wins over the restored one.
# * custom_attributes: plan = 'base', plan_modules, plan_version, plan_applied_at (ISO 8601, Astana time).
#   The trial attributes (plan_type 'trial', trial_expires_at, trial_snapshot ...) are left exactly as they are, and the
#   functions a running trial granted stay switched on (the trial takes them back itself when it ends).
class Accounts::ApplyPlan
  class UnknownModule < ArgumentError; end

  PLAN_KEY = 'plan'
  MODULES_KEY = 'plan_modules'
  VERSION_KEY = 'plan_version'
  APPLIED_AT_KEY = 'plan_applied_at'
  AUDIT_ACTION = 'apply_plan'

  # What applying the plan changes (preview) or changed (call).
  # limits: { 'conversations' => { 'from' => 500, 'to' => 100000 } }
  # kept_limits: the limits chosen for this account that the plan would have changed and left alone: ['conversations']
  # notes : facts the operator should know, e.g. 'trial_active' (the account is on a trial that has its own end),
  #         'trial_locks_limits' (and its end will put the operator and channel limits at zero) or
  #         'trial_limits_restored' (a trial has ended and holds the operator and channel limits at zero: this plan gives
  #         them back, see #trial_limit_restore)
  Diff = Struct.new(:plan, :modules, :plan_version, :previous_plan, :previous_modules, :previous_version,
                    :enable, :disable, :limits, :kept_limits, :notes, keyword_init: true) do
    def changed?
      enable.any? || disable.any? || limits.any?
    end

    def as_json(*)
      {
        'plan' => plan, 'modules' => modules, 'plan_version' => plan_version,
        'previous' => { 'plan' => previous_plan, 'modules' => previous_modules, 'plan_version' => previous_version },
        'enable' => enable, 'disable' => disable, 'limits' => limits, 'kept_limits' => kept_limits, 'notes' => notes, 'changed' => changed?
      }
    end
  end

  attr_reader :account, :modules

  def initialize(account:, modules: [], actor: nil, request: nil)
    @account = account
    @modules = normalize_modules(modules)
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

  def call
    diff = nil
    account.with_lock do
      diff = build_diff
      write(diff)
    end
    SuperAdmin::AccountAudit.record(account: account, actor: @actor, action: AUDIT_ACTION, changes: audit_changes(diff), request: @request)
    diff
  end

  private

  attr_reader :limit_settings

  def normalize_modules(requested)
    Accounts::Plans.normalize_modules(requested)
  rescue ArgumentError => e
    raise UnknownModule, e.message
  end

  def build_diff
    read_limits
    attributes = account.custom_attributes.to_h
    enabled = account.enabled_features.keys
    desired = desired_features

    Diff.new(
      plan: Accounts::Plans::BASE_KEY, modules: modules, plan_version: Accounts::Plans.version,
      previous_plan: attributes[PLAN_KEY], previous_modules: Array(attributes[MODULES_KEY]), previous_version: attributes[VERSION_KEY],
      enable: desired - enabled,
      disable: (Accounts::Plans.managed_features - desired) & enabled,
      limits: limit_changes, kept_limits: kept_limits, notes: notes
    )
  end

  # Read again for every diff: the account is reloaded under its lock before it is written. The numbers of the plan that the limits
  # following it hold are read before anything is written: the zero of a trial that is about to be given back is what tells that a
  # limit follows the plan.
  def read_limits
    @limit_settings = Accounts::LimitSettings.new(account, modules: modules)
    @plan_numbers = limit_settings.following_plan_numbers
  end

  # The flags base + the chosen modules switch on. While a trial runs, the functions it granted count as wanted too
  # (the same expectation as Accounts::PlanDrift): the trial ends by itself and takes them back, so applying or
  # resetting the plan in the meantime must not switch them off early.
  def desired_features
    features = Accounts::Plans.features_for(modules)
    features |= account.granted_trial_features.intersection(Featurable::FEATURE_NAMES) if account.trial_active?
    features
  end

  # The limits that follow the plan get its numbers; the ones chosen for this account stay (see Accounts::LimitSettings#source). The
  # plan is the one being applied: «what their plan would write» for an account that has none yet.
  def limit_changes
    current = account.limits.to_h
    changes = trial_limit_restore(current)
    effective = current.merge(changes.transform_values { |change| change['to'] })
    Accounts::Plans.limits_for(modules).each do |key, value|
      next if value.nil? || effective[key] == value
      next if limit_settings.manual?(key)

      changes[key] = { 'from' => current[key], 'to' => value }
    end
    changes
  end

  # The limits chosen for this account whose number the plan would have changed
  def kept_limits
    Accounts::Plans.limits_for(modules).filter_map do |key, value|
      key if !value.nil? && limit_settings.manual?(key) && limit_settings.effective(key) != value
    end
  end

  # The limits the end of a trial put at 0 and left there, as changes back to what they were before the trial. 'to' is nil for
  # a limit that was not set before: the key is taken off (see #write), the platform's general value applies again.
  def trial_limit_restore(current)
    account.trial_held_limits.to_h { |key, before| [key, { 'from' => current[key], 'to' => before }] }
  end

  def notes
    notes = []
    if account.trial_active?
      notes << 'trial_active'
      # Asked for the moment after the plan is applied: that is when a trial a super admin started keeps the limits
      notes << 'trial_locks_limits' if account.trial_snapshot? && account.trial_locks_limits?(assuming_plan: true)
    end
    # The end of the trial put the operator and channel limits at zero and they are still there: the plan gives them back
    notes << 'trial_limits_restored' if account.trial_held_limits.any?
    notes
  end

  def write(diff)
    account.disable_features(*diff.disable)
    account.enable_features(*diff.enable)
    account.limits = limits_after(diff)
    account.custom_attributes = custom_attributes_after(diff)
    account.save!
  end

  # The attributes with the plan written; the list of the limits chosen by hand stays as it is, and the numbers of the plan the
  # limits that follow it hold are kept for the next time (Accounts::LimitSettings)
  def custom_attributes_after(diff)
    attributes = account.custom_attributes.to_h.deep_dup.merge(plan_attributes(diff))
    if @plan_numbers.empty?
      attributes.delete(Accounts::LimitSettings::PLAN_NUMBERS_KEY)
    else
      attributes[Accounts::LimitSettings::PLAN_NUMBERS_KEY] = @plan_numbers
    end
    attributes
  end

  # The limits of the account with the changes of the plan written; a limit that the plan gives back as «not set» is taken off
  def limits_after(diff)
    written = account.limits.to_h.merge(diff.limits.transform_values { |change| change['to'] })
    written.except(*diff.limits.select { |_key, change| change['to'].nil? }.keys)
  end

  def plan_attributes(diff)
    { PLAN_KEY => diff.plan, MODULES_KEY => diff.modules, VERSION_KEY => diff.plan_version, APPLIED_AT_KEY => Accounts::Plans.astana_now }
  end

  def audit_changes(diff)
    {
      'before' => { 'plan' => diff.previous_plan, 'plan_modules' => diff.previous_modules, 'plan_version' => diff.previous_version },
      'after' => { 'plan' => diff.plan, 'plan_modules' => diff.modules, 'plan_version' => diff.plan_version },
      'features' => { 'enabled' => diff.enable, 'disabled' => diff.disable },
      'limits' => diff.limits
    }.merge(@audit_extra)
  end
end
