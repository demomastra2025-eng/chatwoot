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
#             With keep_existing_limits the account's own values win, the plan only fills the blanks (new accounts).
# * custom_attributes: plan = 'base', plan_modules, plan_version, plan_applied_at (ISO 8601, Astana time).
#   The trial attributes (plan_type 'trial', trial_expires_at, trial_snapshot ...) are left exactly as they are.
class Accounts::ApplyPlan
  class UnknownModule < ArgumentError; end

  PLAN_KEY = 'plan'
  MODULES_KEY = 'plan_modules'
  VERSION_KEY = 'plan_version'
  APPLIED_AT_KEY = 'plan_applied_at'
  AUDIT_ACTION = 'apply_plan'

  # What applying the plan changes (preview) or changed (call).
  # limits: { 'conversations' => { 'from' => 500, 'to' => 100000 } }
  # notes : facts the operator should know, e.g. 'trial_active' (the account is on a trial that has its own end)
  Diff = Struct.new(:plan, :modules, :plan_version, :previous_plan, :previous_modules, :previous_version,
                    :enable, :disable, :limits, :notes, keyword_init: true) do
    def changed?
      enable.any? || disable.any? || limits.any?
    end

    def as_json(*)
      {
        'plan' => plan, 'modules' => modules, 'plan_version' => plan_version,
        'previous' => { 'plan' => previous_plan, 'modules' => previous_modules, 'plan_version' => previous_version },
        'enable' => enable, 'disable' => disable, 'limits' => limits, 'notes' => notes, 'changed' => changed?
      }
    end
  end

  attr_reader :account, :modules

  def initialize(account:, modules: [], actor: nil, request: nil, keep_existing_limits: false)
    @account = account
    @modules = normalize_modules(modules)
    @actor = actor
    @request = request
    @keep_existing_limits = keep_existing_limits
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

  def normalize_modules(requested)
    Accounts::Plans.normalize_modules(requested)
  rescue ArgumentError => e
    raise UnknownModule, e.message
  end

  def build_diff
    attributes = account.custom_attributes.to_h
    enabled = account.enabled_features.keys
    desired = Accounts::Plans.features_for(modules)

    Diff.new(
      plan: Accounts::Plans::BASE_KEY, modules: modules, plan_version: Accounts::Plans.version,
      previous_plan: attributes[PLAN_KEY], previous_modules: Array(attributes[MODULES_KEY]), previous_version: attributes[VERSION_KEY],
      enable: desired - enabled,
      disable: (Accounts::Plans.managed_features - desired) & enabled,
      limits: limit_changes, notes: notes
    )
  end

  def limit_changes
    current = account.limits.to_h
    Accounts::Plans.limits_for(modules).each_with_object({}) do |(key, value), changes|
      next if value.nil? || current[key] == value
      next if @keep_existing_limits && !current[key].nil?

      changes[key] = { 'from' => current[key], 'to' => value }
    end
  end

  def notes
    notes = []
    notes << 'trial_active' if account.trial_active?
    notes << 'trial_expired' if account.trial_snapshot? && account.trial_expired?
    notes
  end

  def write(diff)
    account.disable_features(*diff.disable)
    account.enable_features(*diff.enable)
    account.limits = account.limits.to_h.merge(diff.limits.transform_values { |change| change['to'] })
    account.custom_attributes = account.custom_attributes.to_h.deep_dup.merge(plan_attributes(diff))
    account.save!
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
    }
  end
end
