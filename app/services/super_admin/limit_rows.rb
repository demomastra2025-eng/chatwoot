# frozen_string_literal: true

# The limits of one account as the rows of the card and of the edit form: for every limit the three choices («Как в тарифе»,
# «Без ограничений», «Своё число»), what applies now in words, what the plan gives, and how much is used (SuperAdmin::AccountUsage).
#
#   rows = SuperAdmin::LimitRows.new(account, usage: usage)
#   rows.rows.each { |row| row.label, row.choice, row.now, row.plan_detail, row.input_value ... }
#
# Two numbers are said apart, so they never look like one that contradicts the other: `now` is what applies now («Сейчас: 5 операторов»),
# `plan_detail` is what «Как в тарифе» gives («по тарифу: без ограничений»).
#
# `state` is what the operator typed when the form comes back with a problem (SuperAdmin::LimitForm#state): the rows are drawn
# with those choices and numbers instead of the saved ones, and `problems` marks the limits that were not understood.
class SuperAdmin::LimitRows
  Row = Struct.new(
    :key, :usage_key, :label, :input_label, :hint, :bytes, :choice, :input_value, :now, :plan_text, :plan_detail, :drift, :held, :usage,
    :problem,
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
      plan_detail: plan_detail(key),
      drift: drift_text(key, source, usage_row),
      held: held_text(key),
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

    # With the comma the words use («1,5 ГБ»); the form takes the comma and the dot alike (SuperAdmin::LimitForm)
    ActiveSupport::NumberHelper.number_to_rounded(value.to_f / 1.gigabyte, precision: Accounts::LimitSettings::GIGABYTE_DECIMALS,
                                                                           strip_insignificant_zeros: true, separator: ',')
  end

  # What «Как в тарифе» gives, said as what the plan gives («по тарифу: 5 операторов»); where the plan has no number the general value of
  # the platform is meant (an account without a plan always)
  def plan_detail(key)
    general = @settings.plan_value(key).nil? && (!plan_assigned? || !@settings.global_value(key).nil?)
    I18n.t(general ? 'super_admin.limits.choices.plan_general' : 'super_admin.limits.choices.plan_now',
           value: SuperAdmin::LimitWords.amount(key, @settings.plan_following_value(key)))
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

  # A limit that follows the plan but still holds an older number of it: the plan writes the new one when it is applied (the zero of an
  # ended trial has a note of its own)
  def drift_text(key, source, usage_row)
    plan = @settings.plan_value(key)
    return if source != :plan || plan.nil? || @settings.stored(key) == plan || held?(key)

    I18n.t('super_admin.limits.drift', now: SuperAdmin::LimitWords.amount(key, applying(key, usage_row)),
                                       plan: SuperAdmin::LimitWords.amount(key, plan))
  end

  # The zero the end of a trial put on the limit and still holds there: the limit says «как в тарифе», and without this line nothing
  # says why it is 0 (applying the plan gives it back, and says what it gives back)
  def held_text(key)
    return unless held?(key)

    I18n.t('super_admin.limits.held', value: SuperAdmin::LimitWords.amount(key, restored_number(key)))
  end

  # The number the limit gets when the plan is applied (Accounts::ApplyPlan): the number of the plan where it has one, else the number
  # from before the trial; without either the general value of the platform applies again (nil: no limit)
  def restored_number(key)
    plan = plan_assigned? ? @settings.plan_value(key) : Accounts::Plans.limits_for([])[key]
    plan.nil? ? (held[key] || @settings.global_value(key)) : plan
  end

  def held?(key)
    held.key?(key)
  end

  # { 'agents' => 5 }: the limits the end of a trial holds at 0, with the number each had before the trial (nil: it had none)
  def held
    @held ||= @account.trial_held_limits
  end
end
