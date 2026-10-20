# frozen_string_literal: true

# Where every limit of an account comes from, and what Account#limits has to hold for the choice made for each limit.
#
# For every limit (operators, channels, conversations ...) the super admin picks ONE of three things:
#
#   :plan        «Как в тарифе»    the number of the plan of the account. Where the plan has none, the general value of the
#                                  platform (an installation setting such as ACCOUNT_CONVERSATIONS_LIMIT); without that, no limit.
#   :unlimited   «Без ограничений»
#   Integer      «Своё число»      a number only for this account (bytes for the storage; the screens speak gigabytes)
#
# The code that enforces the limits reads Account#limits and nothing else (Enterprise::Account::PlanUsageAndLimits,
# AccountLimits::StorageUsageService ...), and so do the lists. So the numbers that apply stay in Account#limits, exactly as before,
# and what that hash cannot tell - whether a number was written by a plan or chosen by hand - is kept beside it:
#
#   account.custom_attributes['limit_overrides'] = { 'agents' => 5, 'conversations' => 'unlimited' }
#
# Only the limits chosen by hand are listed (an Integer, or 'unlimited'); every other limit follows the plan. The key is written by
# the screens of the super admin and by Accounts::ApplyPlan, and it is never lost: a plan, a trial or the Platform API leaves
# the listed limits as they are.
#
# An account that has no such key yet (every account that existed before this) is read like this, and nothing is written for it:
# a number that equals what its plan would write is «как в тарифе», any other number is «своё число» (or «без ограничений» for the
# number that stands for no limit), and a limit with no number follows the plan. An account that has the key (even an empty one)
# is tracked: a number it holds that is not listed and differs from a number of its plan is an older number of the plan, not a
# choice (the plan writes the new one when it is applied).
#
#   settings = Accounts::LimitSettings.new(account)
#   settings.source('agents')       # => :plan | :unlimited | :custom
#   settings.effective('agents')    # => 5 (what the code enforces now); nil = no limit
#   result = settings.apply('agents' => 5, 'conversations' => :unlimited, 'storage_bytes' => :plan)
#   account.update!(limits: result.limits, custom_attributes: account.custom_attributes.merge(described_class::KEY => result.marks))
class Accounts::LimitSettings
  KEY = 'limit_overrides'
  UNLIMITED = Accounts::Plans::UNLIMITED

  # The setting of the platform that gives a limit its general value (the same names the enforcement code reads). A limit without
  # a setting has no general value.
  GLOBAL_SETTINGS = {
    'agents' => 'ACCOUNT_AGENTS_LIMIT',
    'inboxes' => 'ACCOUNT_INBOXES_LIMIT',
    'conversations' => 'ACCOUNT_CONVERSATIONS_LIMIT',
    'non_web_inboxes' => 'ACCOUNT_NON_WEB_INBOXES_LIMIT',
    'storage_bytes' => 'ACCOUNT_STORAGE_BYTES_LIMIT',
    'captain_tokens' => 'ACCOUNT_CAPTAIN_TOKENS_LIMIT',
    'emails' => 'ACCOUNT_EMAILS_LIMIT'
  }.freeze

  # What applying a choice gives: the new Account#limits, the new list of the limits chosen by hand, and for each limit whose choice
  # or number changed { 'from' => Position, 'to' => Position }.
  Result = Struct.new(:limits, :marks, :changes, keyword_init: true)
  # One limit as it stands: where it comes from (:plan, :unlimited or :custom) and the number that applies (nil: no limit)
  Position = Struct.new(:source, :value, keyword_init: true)

  class << self
    # The limits chosen by hand, as { 'agents' => 5, 'conversations' => 'unlimited' }, from the custom attributes of an account. A
    # malformed entry (an unknown limit, a negative or fractional number, anything else) is ignored.
    def marks_in(attributes)
      raw = attributes.to_h[KEY]
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(key, mark), marks|
        key = key.to_s
        marks[key] = mark if Accounts::Plans::LIMIT_KEYS.include?(key) && valid_mark?(mark)
      end
    end

    # Whether the custom attributes hold the list at all (an empty list counts: it says that nothing was chosen by hand)
    def tracked?(attributes)
      attributes.to_h[KEY].is_a?(Hash)
    end

    def valid_mark?(mark)
      mark == UNLIMITED || (mark.is_a?(Integer) && !mark.negative?)
    end
  end

  # modules: the modules of the plan to read the plan numbers from (default: the plan applied to the account, none without one)
  # limits : the limits to read instead of the ones of the account (what Accounts::ApplyPlan is about to write)
  # marks  : the list of the limits chosen by hand to read instead of the one of the account
  def initialize(account, modules: nil, limits: nil, marks: nil)
    @account = account
    @modules = modules
    @limits = limits
    @given_marks = marks
  end

  def tracked?
    @given_marks ? true : self.class.tracked?(attributes)
  end

  # { 'agents' => 5, 'conversations' => 'unlimited' }: the limits chosen by hand as they are listed
  def marks
    @marks ||= @given_marks || self.class.marks_in(attributes)
  end

  # The number in Account#limits; nil when the limit has none
  def stored(key)
    value = stored_limits[key.to_s]
    value.nil? || value == '' ? nil : value
  end

  # What the plan writes for the limit: a number (the number of `unlimited` included), or nil when the account has no plan or
  # the plan leaves the limit alone
  def plan_value(key)
    plan_assigned? ? plan_limits[key.to_s] : nil
  end

  # The general value of the platform for the limit (nil: there is none)
  def global_value(key)
    name = GLOBAL_SETTINGS[key.to_s]
    return unless name

    value = GlobalConfig.get(name)[name]
    value.blank? ? nil : value.to_i
  end

  # The number the code enforces now: the one in Account#limits, else the general value of the platform; nil is no limit
  def effective(key)
    stored(key) || global_value(key)
  end

  # What «как в тарифе» gives the limit: the number of the plan, else the general value of the platform; nil is no limit
  def plan_following_value(key)
    plan_value(key) || global_value(key)
  end

  # Where the number of the limit comes from: :plan, :unlimited or :custom
  def source(key)
    key = key.to_s
    mark = marks[key]
    return mark == UNLIMITED ? :unlimited : :custom if mark

    value = stored(key)
    return :plan if value.nil? || held?(key) || follows_plan_number?(key, value)

    Accounts::Plans.unlimited_value?(key, value) ? :unlimited : :custom
  end

  # A number or «без ограничений» chosen for this account
  def manual?(key)
    source(key) != :plan
  end

  # The number of «своё число»: the one chosen (or, for an account that chose nothing yet, the one it holds); nil for the other choices
  def custom_value(key)
    return unless source(key) == :custom

    number = marks[key.to_s] || stored(key)
    number.is_a?(Numeric) ? number.round : nil
  end

  # The choice as the form takes it: :plan, :unlimited or the Integer of «своё число»
  def choice(key)
    case source(key)
    when :plan then :plan
    when :unlimited then :unlimited
    else custom_value(key)
    end
  end

  # { 'key' => Position } for every limit
  def positions
    Accounts::Plans::LIMIT_KEYS.index_with { |key| Position.new(source: source(key), value: effective(key)) }
  end

  # The list of the limits chosen by hand as it has to be stored now: the list the account has, plus the numbers it holds that
  # are its own (an account from before the list, a number somebody typed into a plan limit)
  def materialized_marks
    Accounts::Plans::LIMIT_KEYS.each_with_object({}) do |key, marks|
      case source(key)
      when :unlimited then marks[key] = UNLIMITED
      when :custom then marks[key] = custom_value(key)
      end
    end
  end

  # The list to store when a plan is applied: the limits chosen by hand that are listed already, and the numbers the account holds
  # where the plan has a number of its own (an account that is tracked from now on would take them for an older number of the
  # plan and write the new one over them). A number in a limit the plan leaves alone is the account's own without being listed.
  def plan_marks
    materialized_marks.select { |key, _mark| marks.key?(key) || !plan_value(key).nil? }
  end

  # What Account#limits and the list of limits chosen by hand become when `choices` ({ 'agents' => 5, 'storage_bytes' => :plan })
  # are made; the limits that are not named stay as they are. Nothing is written.
  def apply(choices)
    limits = stored_limits.dup
    marks = materialized_marks
    choices.each do |key, choice|
      key = key.to_s
      next unless Accounts::Plans::LIMIT_KEYS.include?(key)

      apply_choice(limits, marks, key, choice)
    end
    Result.new(limits: limits, marks: marks, changes: changes_between(limits, marks))
  end

  private

  def apply_choice(limits, marks, key, choice)
    case choice
    when :plan
      marks.delete(key)
      plan = plan_value(key)
      plan.nil? ? limits.delete(key) : limits[key] = plan
    when :unlimited
      marks[key] = UNLIMITED
      limits[key] = Accounts::Plans.unlimited_value(key)
    else
      raise ArgumentError, "Not a choice for #{key}: #{choice.inspect}" unless choice.is_a?(Integer) && !choice.negative?

      marks[key] = choice
      limits[key] = choice
    end
  end

  # { 'agents' => { 'from' => Position, 'to' => Position } } for the limits whose source or number differs after the choices
  def changes_between(limits, marks)
    after = self.class.new(@account, modules: @modules, limits: limits, marks: marks)
    Accounts::Plans::LIMIT_KEYS.each_with_object({}) do |key, changes|
      before = Position.new(source: source(key), value: effective(key))
      now = Position.new(source: after.source(key), value: after.effective(key))
      changes[key] = { 'from' => before, 'to' => now } if before != now
    end
  end

  def attributes
    @account.custom_attributes.to_h
  end

  def stored_limits
    @stored_limits ||= (@limits || @account.limits).to_h.transform_keys(&:to_s)
  end

  def plan_assigned?
    @modules ? true : attributes[Accounts::ApplyPlan::PLAN_KEY].present?
  end

  def plan_limits
    @plan_limits ||= Accounts::Plans.limits_for(plan_modules)
  end

  def plan_modules
    @modules || Accounts::Plans.known_modules(attributes[Accounts::ApplyPlan::MODULES_KEY])
  end

  # The zero a trial left on a limit is the platform's, not a choice
  def held?(key)
    return false if @limits

    @held ||= @account.trial_held_limits
    @held.key?(key.to_s)
  end

  # The number is the one of the plan, or (for an account that is tracked) an older number of it that the plan writes over
  def follows_plan_number?(key, value)
    plan = plan_value(key)
    !plan.nil? && (same_number?(plan, value) || tracked?)
  end

  def same_number?(first, second)
    first.is_a?(Numeric) && second.is_a?(Numeric) && first == second
  end
end
