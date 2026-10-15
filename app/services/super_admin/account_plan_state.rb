# frozen_string_literal: true

# What the plan of one clinic looks like on screen: the plan and its modules, how far the flags have moved away from it
# ("changed by hand"), the trial, and the status of the clinic. It only reads the account (custom_attributes and the
# feature flags), so it costs no queries and is safe to build for every row of a list.
#
#   state = SuperAdmin::AccountPlanState.new(account)
#   state.label      # => "База + ИИ-агенты", or "Не назначен"
#   state.chips      # => [Chip(text: "База", tone: :iris), Chip(text: "ИИ-агенты", tone: :slate), ...]
#   state.drift      # => { extra: ["sla"], missing: [] }  (nil when the clinic has no plan)
#   state.trial_state # => :none | :active | :expired
#   state.status     # => :active | :suspended | :deleting (state.status_label is its Russian name)
class SuperAdmin::AccountPlanState
  Chip = Struct.new(:text, :tone, keyword_init: true)

  # A trial that has this little time left is shown as a warning
  TRIAL_WARNING_SECONDS = 1.day.to_i

  attr_reader :account

  def initialize(account)
    @account = account
  end

  # :deleting beats :suspended beats :active. The one place that decides what status a clinic shows (card, list, CSV).
  def status
    return :deleting if attributes['marked_for_deletion_at'].present?

    account.suspended? ? :suspended : :active
  end

  def status_label
    I18n.t("super_admin.accounts.statuses.#{status}")
  end

  def assigned?
    attributes[Accounts::ApplyPlan::PLAN_KEY].present?
  end

  # The modules that were chosen and still exist in the registry, in registry order
  def modules
    Accounts::Plans.known_modules(attributes[Accounts::ApplyPlan::MODULES_KEY])
  end

  def label
    assigned? ? Accounts::Plans.plan_label(modules) : I18n.t('super_admin.plans.not_assigned')
  end

  def version
    attributes[Accounts::ApplyPlan::VERSION_KEY]
  end

  # When the plan was applied (Time), nil when unknown
  def applied_at
    Time.zone.parse(attributes[Accounts::ApplyPlan::APPLIED_AT_KEY].to_s)
  rescue ArgumentError
    nil
  end

  # { extra: [flag names on beyond the plan], missing: [flag names off that the plan has on] }; nil without a plan
  def drift
    return @drift if defined?(@drift)

    @drift = Accounts::PlanDrift.call(account)
  end

  def drifted?
    drift.present? && (drift[:extra].any? || drift[:missing].any?)
  end

  # --------------------------------------------------------------------- trial

  def trial_state
    return :none unless account.trial?

    account.trial_active? ? :active : :expired
  end

  # A trial that the admin panel started: it has a snapshot, so it can be extended and ended early
  def trial_managed?
    account.trial? && account.trial_snapshot?
  end

  def can_start_trial?
    return false if trial_managed?

    attributes['plan_type'].blank? || account.trial?
  end

  # Whether the end of the trial blocks new operators and channels. A trial that exists says so itself; for the trial
  # the card could start it depends on the plan (a trial a super admin starts on a clinic with a plan keeps the limits).
  def trial_locks_limits?
    return account.trial_locks_limits? if trial_managed?

    !assigned?
  end

  def trial_expires_at
    account.trial_expires_at
  end

  def trial_expired_at
    Time.zone.parse(attributes['trial_expired_at'].to_s)
  rescue ArgumentError
    nil
  end

  # { days:, hours:, minutes: } left of an active trial, nil otherwise
  def trial_remaining
    return unless trial_state == :active

    seconds = (trial_expires_at - Time.current).to_i
    { days: seconds / 1.day.to_i, hours: (seconds % 1.day.to_i) / 1.hour.to_i, minutes: (seconds % 1.hour.to_i) / 1.minute.to_i }
  end

  # "3 дн.", "5 ч.", "40 мин." (rounded up, so a trial that has just started for 3 days says "3 дн.")
  def trial_remaining_short
    return unless trial_state == :active

    seconds = trial_remaining_seconds
    if seconds >= 1.day.to_i
      I18n.t('super_admin.accounts.trial.short_days', count: (seconds / 1.day.to_f).ceil)
    elsif seconds >= 1.hour.to_i
      I18n.t('super_admin.accounts.trial.short_hours', count: (seconds / 1.hour.to_f).ceil)
    else
      I18n.t('super_admin.accounts.trial.short_minutes', count: [(seconds / 1.minute.to_f).ceil, 1].max)
    end
  end

  # ---------------------------------------------------------------------- chips

  # The plan column of the list: base + modules, or «Не назначен», plus the trial
  def chips
    list = []
    if assigned?
      list << Chip.new(text: I18n.t('super_admin.plans.base.name'), tone: :iris)
      modules.each { |key| list << Chip.new(text: Accounts::Plans.module_name(key), tone: :slate) }
    end
    list << trial_chip if trial_state != :none
    list << Chip.new(text: I18n.t('super_admin.plans.not_assigned'), tone: :quiet) if list.empty?
    list
  end

  private

  def attributes
    @attributes ||= account.custom_attributes.to_h
  end

  def trial_chip
    if trial_state == :active
      warning = trial_remaining_seconds < TRIAL_WARNING_SECONDS
      Chip.new(text: I18n.t('super_admin.accounts.trial.chip_active', left: trial_remaining_short), tone: warning ? :amber : :blue)
    else
      Chip.new(text: I18n.t('super_admin.accounts.trial.chip_expired'), tone: :ruby)
    end
  end

  def trial_remaining_seconds
    (trial_expires_at - Time.current).to_i
  end
end
