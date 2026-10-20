require 'administrate/field/base'

# The limits of a clinic on its forms: one row per limit with three choices («Как в тарифе», «Без ограничений», «Своё число»),
# see SuperAdmin::LimitRows and Accounts::LimitSettings. The Russian name and hint of every limit live in
# super_admin.limits.<key>.{label,hint}.
class AccountLimitsField < Administrate::Field::Base
  # The rows of the limits of the account, drawn with what was typed when the form comes back with a problem
  def rows(state: nil, problems: nil)
    SuperAdmin::LimitRows.new(resource, state: state, problems: problems)
  end

  # The limits chosen for the account by hand, in words
  def to_s
    settings = Accounts::LimitSettings.new(resource)
    Accounts::Plans::LIMIT_KEYS.filter_map do |key|
      next unless settings.manual?(key)

      "#{I18n.t("super_admin.limits.#{key}.label")}: #{SuperAdmin::LimitWords.amount(key, settings.effective(key))}"
    end.join(', ')
  end
end
