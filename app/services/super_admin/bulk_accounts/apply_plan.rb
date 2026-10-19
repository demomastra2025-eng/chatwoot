# frozen_string_literal: true

# Applies the base plan and the chosen modules (`modules`) to the accounts: the same thing «Применить» does on the card of
# an account (Accounts::ApplyPlan), whose preview is what the confirmation page summarises. An account that already has
# exactly this plan and nothing to switch is skipped.
class SuperAdmin::BulkAccounts::ApplyPlan < SuperAdmin::BulkAccounts::Base
  def parameter? = true

  # The keys of the modules chosen, in the order of the registry; empty (the base alone) when none is chosen. Nil when the
  # request names a module that does not exist or sends the list in a wrong shape.
  def modules
    return @modules if defined?(@modules)

    raw = options[:modules]
    @modules = case raw
               when nil, '', [] then []
               when Array, String then ::Accounts::Plans.normalize_modules(raw)
               end
  rescue ArgumentError
    @modules = nil
  end

  def error = (:unknown_module if modules.nil?)

  def evaluate(account)
    diff = plan_for(account).preview
    return skip(account, :no_changes, diff: diff) if same_plan?(diff)

    change(account, diff: diff)
  end

  def perform(account)
    plan_for(account).call
    nil
  end

  private

  def plan_for(account)
    ::Accounts::ApplyPlan.new(account: account, modules: modules, actor: actor, request: request,
                              audit_extra: SuperAdmin::BulkAccounts::AUDIT_EXTRA)
  end

  # Nothing to switch, no limit to move, and the account already says it is on this plan and version
  def same_plan?(diff)
    !diff.changed? && diff.previous_plan == diff.plan && diff.previous_modules.sort == diff.modules.sort &&
      diff.previous_version == diff.plan_version
  end
end
