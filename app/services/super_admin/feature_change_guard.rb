# frozen_string_literal: true

# Which function switches of ONE clinic a super admin may change (the edit form, «Тонкая настройка» and «Служебные»).
#
# The screens only offer what is allowed, so this is the check of the server for a request that was built by hand or
# came from an old page. A change is a wanted state that differs from the state of the clinic now; asking for the state
# the clinic already has is never a violation, so a clinic that has a function no plan ever enables (scheduling_finance
# on a clinic that got it earlier) can still be saved, and the function can be switched off.
#
#   guard = SuperAdmin::FeatureChangeGuard.new(account)
#   guard.violations('crm' => true, 'saml' => true)  # => [Violation(flag: 'saml', reason: :never_enabled)]
#
# Rules (config/account_plans.yml):
#   * the owner-decision flags (SuperAdmin::FineTuning::OWNER_DECISION_FLAGS) may always be changed;
#   * a flag in `never_enabled` may be switched off, never on;
#   * a flag in `locked_on` may be switched on, never off;
#   * any other `internal` flag, and a flag no place of the plans names, may not be changed at all.
class SuperAdmin::FeatureChangeGuard
  Violation = Struct.new(:flag, :reason, keyword_init: true) do
    def message
      I18n.t("super_admin.accounts.flashes.feature_rejected.#{reason}", feature: SuperAdmin::AccountFeaturesHelper.feature_label(flag))
    end
  end

  # account: the clinic (an unsaved Account.new for a clinic that is being created)
  def initialize(account)
    @account = account
  end

  # requested: { 'flag' => true | false }. Only the flags whose wanted state differs from the clinic's now.
  def changes(requested)
    requested.to_h.reject { |flag, wanted| @account.feature_enabled?(flag) == wanted }
  end

  def violations(requested)
    changes(requested).filter_map do |flag, wanted|
      reason = reason_for(flag, wanted)
      Violation.new(flag: flag, reason: reason) if reason
    end
  end

  # The one sentence a flash shows for all violations
  def message(requested)
    list = violations(requested)
    return if list.empty?

    I18n.t('super_admin.accounts.flashes.feature_change_rejected', details: list.map(&:message).join(' '))
  end

  private

  def reason_for(flag, wanted)
    return if SuperAdmin::FineTuning::OWNER_DECISION_FLAGS.include?(flag)
    return :never_enabled if wanted && Accounts::Plans.never_enabled.include?(flag)
    return :locked_on if !wanted && Accounts::Plans.locked_on.include?(flag)
    return :internal if Accounts::Plans.internal.include?(flag) || !Accounts::Plans.classified_features.include?(flag)

    nil
  end
end
