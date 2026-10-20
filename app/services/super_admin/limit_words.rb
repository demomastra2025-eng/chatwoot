# frozen_string_literal: true

# The limits of an account in plain Russian words, for the screens and for the audit log: «5 операторов», «50 ГБ», «без ограничений»,
# and a limit as it stands («как в тарифе (без ограничений)», «своё число: 5 операторов»). The words of every limit are in
# super_admin.limits.units.<key>.
#
#   SuperAdmin::LimitWords.amount('agents', 5)               # => "5 операторов"
#   SuperAdmin::LimitWords.amount('storage_bytes', 50.gigabytes) # => "50 ГБ"
#   SuperAdmin::LimitWords.amount('storage_bytes', 5_000_000_000) # => "4,66 ГБ" (the decimals of the field the size is typed in)
#   SuperAdmin::LimitWords.amount('agents', nil)             # => "без ограничений"
module SuperAdmin::LimitWords
  # The keys of the limits in the order of the screens (operators first)
  SCREEN_ORDER = SuperAdmin::AccountUsage::DEFINITIONS.map { |_usage_key, limit_key, _path, _bytes| limit_key }.freeze

  module_function

  # The number with its noun; a missing number and the number that stands for no limit are «без ограничений». 0 is said as it is: the
  # action is forbidden.
  def amount(key, value)
    return I18n.t('super_admin.limits.unlimited_phrase') if value.nil? || Accounts::Plans.unlimited_value?(key, value)
    return storage_size(value) if key.to_s == 'storage_bytes'

    I18n.t("super_admin.limits.units.#{key}", count: value.to_i, number: SuperAdmin::DisplayHelper.format_number(value.to_i))
  end

  # A size in gigabytes with the decimals of the field it is typed in (a size of 4,66 ГБ is not said as 4,7), below a gigabyte as the
  # screens say any size
  def storage_size(bytes)
    return SuperAdmin::DisplayHelper.format_bytes(bytes) if bytes.to_f < 1.gigabyte

    options = { precision: Accounts::LimitSettings::GIGABYTE_DECIMALS, strip_insignificant_zeros: true }
    number = ActiveSupport::NumberHelper.number_to_rounded(bytes.to_f / 1.gigabyte, **options, **SuperAdmin::DisplayHelper::NUMBER_OPTIONS)
    "#{number} #{I18n.t('super_admin.limits.gigabytes')}"
  end

  # A limit as it stands, for a sentence of the audit log: «как в тарифе (5 операторов)», «без ограничений», «своё число (8 операторов)».
  # `position` is an Accounts::LimitSettings::Position.
  def position(key, position)
    case position.source
    when :plan then I18n.t('super_admin.limits.audit.plan', value: amount(key, position.value))
    when :unlimited then I18n.t('super_admin.limits.audit.unlimited')
    else I18n.t('super_admin.limits.audit.custom', value: amount(key, position.value))
    end
  end

  # The changes of Accounts::LimitSettings::Result for the audit log, in words:
  # { 'agents' => { 'label' => 'Операторы', 'from' => 'как в тарифе (без ограничений)', 'to' => 'своё число (5 операторов)' } }
  def audit_changes(changes)
    ordered = changes.sort_by { |key, _change| SCREEN_ORDER.index(key) || SCREEN_ORDER.size }
    words = ordered.to_h do |key, change|
      [key, { 'label' => I18n.t("super_admin.limits.#{key}.label"), 'from' => position(key, change['from']), 'to' => position(key, change['to']) }]
    end
    # A change the words cannot tell apart says nothing to the person who reads the log
    words.reject { |_key, change| change['from'] == change['to'] }
  end
end
