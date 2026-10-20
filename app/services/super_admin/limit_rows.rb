# frozen_string_literal: true

# The limits of one account as the rows of the card and of the edit form: for every limit the three choices («Как в тарифе»,
# «Без ограничений», «Своё число»), what applies now in words, what the plan gives, and how much is used (SuperAdmin::AccountUsage).
#
#   rows = SuperAdmin::LimitRows.new(account, usage: usage)
#   rows.rows.each { |row| row.label, row.choice, row.now, row.plan_text, row.input_value ... }
#
# `state` is what the operator typed when the form comes back with a problem (SuperAdmin::LimitForm#state): the rows are drawn
# with those choices and numbers instead of the saved ones, and `problems` marks the limits that were not understood.
class SuperAdmin::LimitRows
  Row = Struct.new(
    :key, :usage_key, :label, :input_label, :hint, :bytes, :choice, :input_value, :now, :plan_text, :drift, :usage, :problem,
    keyword_init: true
  )

  attr_reader :settings

  def initialize(account, usage: nil, state: nil, problems: nil)
    @account = account
    @usage = usage || SuperAdmin::AccountUsage.new(account)
    @state = state || {}
    @problems = problems || {}
    @settings = Accounts::LimitSettings.new(account)
  end

  # Whether a plan is applied to the account: without one «как в тарифе» means the general values of the platform
  def plan_assigned?
    @account.custom_attributes.to_h[Accounts::ApplyPlan::PLAN_KEY].present?
  end

  def rows
    @rows ||= SuperAdmin::AccountUsage::DEFINITIONS.map { |usage_key, limit_key, _path, bytes| build(usage_key, limit_key, bytes) }
  end

  private

  def build(usage_key, key, bytes)
    usage_row = @usage.row(usage_key)
    source = @settings.source(key)
    Row.new(
      key: key, usage_key: usage_key, usage: usage_row, bytes: bytes,
      label: I18n.t("super_admin.limits.#{key}.label"),
      input_label: I18n.t("super_admin.limits.#{key}.input_label", default: I18n.t("super_admin.limits.#{key}.label")),
      hint: I18n.t("super_admin.limits.#{key}.hint"),
      choice: typed_choice(key) || source.to_s,
      input_value: typed_value(key) || input_number(key, bytes),
      now: now_text(key, usage_row),
      plan_text: SuperAdmin::LimitWords.amount(key, @settings.plan_following_value(key)),
      drift: drift_text(key, source, usage_row),
      problem: @problems[key]
    )
  end

  def typed_choice(key)
    @state.dig(key, 'choice').presence
  end

  def typed_value(key)
    return unless @state.key?(key)

    @state.dig(key, 'value').to_s
  end

  # The number the field starts with: the number of «своё число», or the number that applies now (so a switch to «Своё число»
  # starts from it); nothing when there is no limit. Gigabytes for the storage.
  def input_number(key, bytes)
    value = @settings.custom_value(key)
    value ||= @settings.effective(key) unless Accounts::Plans.unlimited_value?(key, @settings.effective(key))
    return if value.nil?

    return value.round.to_s unless bytes

    ActiveSupport::NumberHelper.number_to_rounded(value.to_f / 1.gigabyte, precision: 2, strip_insignificant_zeros: true)
  end

  # What applies now, from the same numbers the usage meter is drawn from (they are what the code enforces)
  def now_text(key, usage_row)
    text = I18n.t('super_admin.limits.now', value: SuperAdmin::LimitWords.amount(key, applying(key, usage_row)))
    usage_row&.blocked? ? "#{text} #{I18n.t('super_admin.limits.forbidden')}" : text
  end

  # The number that applies now (nil: no limit)
  def applying(key, usage_row)
    return @settings.effective(key) unless usage_row

    usage_row.unlimited ? nil : usage_row.total
  end

  # A limit that follows the plan but still holds an older number of it: the plan writes the new one when it is applied
  def drift_text(key, source, usage_row)
    plan = @settings.plan_value(key)
    return if source != :plan || plan.nil? || @settings.stored(key) == plan

    I18n.t('super_admin.limits.drift', now: SuperAdmin::LimitWords.amount(key, applying(key, usage_row)),
                                       plan: SuperAdmin::LimitWords.amount(key, plan))
  end
end
