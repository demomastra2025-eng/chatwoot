# frozen_string_literal: true

# How far an account has moved away from the plan that was applied to it ("changed by hand").
#
#   Accounts::PlanDrift.call(account) # => nil                               the account has no plan
#                                     # => { extra: [...], missing: [...] }   flags that are on but should not be / off but should be
#
# Only the classified, non-internal flags are compared (base, modules, locked_on, never_enabled); internal flags are
# not part of any plan. A running snapshot-backed trial adds what the trial granted to the expected set, so a new
# account on its trial does not show up as changed.
class Accounts::PlanDrift
  def self.call(account)
    new(account).call
  end

  def initialize(account)
    @account = account
  end

  def call
    return nil if applied_plan.blank?

    expected = expected_features
    enabled = @account.enabled_features.keys
    {
      extra: Accounts::Plans.managed_features.select { |name| enabled.include?(name) && expected.exclude?(name) },
      missing: expected.select { |name| enabled.exclude?(name) }
    }
  end

  private

  def applied_plan
    @account.custom_attributes.to_h[Accounts::ApplyPlan::PLAN_KEY]
  end

  # Modules that were chosen and still exist in the registry
  def applied_modules
    Accounts::Plans.module_keys & Array(@account.custom_attributes.to_h[Accounts::ApplyPlan::MODULES_KEY]).map(&:to_s)
  end

  def expected_features
    features = Accounts::Plans.features_for(applied_modules)
    features |= @account.granted_trial_features if @account.trial_active?
    features.intersection(Featurable::FEATURE_NAMES)
  end
end
