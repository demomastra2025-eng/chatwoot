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
# the screens of the super admin, and it is never lost: a plan, a trial or the Platform API leaves the listed limits as they are.
#
# A number that follows the plan is not listed, so it has to be told from a number somebody typed. A limit follows the plan when
# it holds no number, when the end of a trial holds it at 0, or when its number is the number of the plan now or the number the plan
# wrote last. The last one is kept beside the list:
#
#   account.custom_attributes['limit_plan_numbers'] = { 'conversations' => 1000 }
#
# (the numbers Accounts::ApplyPlan and the choice «Как в тарифе» wrote). So a number of the plan that has changed since is still told
# from a number of the account: the limit follows the plan, and the plan writes its new number when it is applied. Any other number
# is «своё число» (or «без ограничений» for the number that stands for no limit), whoever typed it: the screens of the super admin,
# an older form, the Platform API.
#
# An account that has neither key (every account that existed before this) is read the same way, and nothing is written for it: a
# number that equals what its plan would write is «как в тарифе», any other number is «своё число», and a limit with no number
# follows the plan. Saving a form leaves alone every limit whose choice did not change (#apply), so nothing is written for the limits
# nobody touched: a zero a trial put on a limit, a number a partner wrote, a number the plan has changed since stay as they are.
#
# The plan of such an account was written by the plans of that time, and what they wrote is known: LEGACY_PLAN_NUMBERS. For a limit
# of an account that has a plan and no number of the plan kept for the limit, that is the number the plan wrote last. So the account
# keeps following the plan when the numbers of the file change before anybody has applied the plan again (the file said `unlimited`,
# the account holds 100 000, the file now says 2000: the limit still follows the plan, and the plan writes 2000 when it is applied).
#
#   settings = Accounts::LimitSettings.new(account)
#   settings.source('agents')       # => :plan | :unlimited | :custom
#   settings.effective('agents')    # => 5 (what the code enforces now); nil = no limit
#   result = settings.apply('agents' => 5, 'conversations' => :unlimited, 'storage_bytes' => :plan)
#   account.update!(limits: result.limits, custom_attributes: result.custom_attributes(account.custom_attributes))
class Accounts::LimitSettings # rubocop:disable Metrics/ClassLength
  KEY = 'limit_overrides'
  PLAN_NUMBERS_KEY = 'limit_plan_numbers'
  # What this class keeps in the custom attributes of an account (code that replaces the attributes as a whole has to keep both)
  ATTRIBUTE_KEYS = [KEY, PLAN_NUMBERS_KEY].freeze
  UNLIMITED = Accounts::Plans::UNLIMITED
  # The storage is typed and shown in gigabytes with this many decimals (1,5 or 4,66); two sizes that differ by less are the same size
  GIGABYTE_DECIMALS = 2

  # What the plans before the lists of this file (plan_version 1 and 2) wrote into the limits of an account: these two numbers, the
  # number that stands for no limit of a count, and no other. The file with the numbers of the plan has changed since, so this table,
  # not the file, says what an account whose plan was applied before the lists was written with (see the top of this file). The number is
  # the value ChatwootApp.max_limit had then; it stays in the accounts whatever the value is later.
  LEGACY_PLAN_NUMBERS = { 'conversations' => 100_000, 'non_web_inboxes' => 100_000 }.freeze

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

  # What applying a choice gives: the new Account#limits, the new list of the limits chosen by hand, the new list of the numbers of the
  # plan the limits hold, and for each limit whose choice or number changed { 'from' => Position, 'to' => Position }.
  Result = Struct.new(:limits, :marks, :plan_numbers, :changes, keyword_init: true) do
    # The custom attributes of the account with the two lists set (a list that is empty is not stored)
    def custom_attributes(attributes)
      attributes = attributes.to_h.deep_dup
      { KEY => marks, PLAN_NUMBERS_KEY => plan_numbers }.each do |name, list|
        list.empty? ? attributes.delete(name) : attributes[name] = list
      end
      attributes
    end
  end
  # The three lists as they are while choices are applied to them (or once they are), and the limits an ended trial still holds at 0
  # among those nobody has chosen anything for
  Draft = Struct.new(:limits, :marks, :plan_numbers, :held)
  # One limit as it stands: where it comes from (:plan, :unlimited or :custom) and the number that applies (nil: no limit)
  Position = Struct.new(:source, :value, keyword_init: true)

  class << self
    # The limits chosen by hand, as { 'agents' => 5, 'conversations' => 'unlimited' }, from the custom attributes of an account. A
    # malformed entry (an unknown limit, a negative or fractional number, anything else) is ignored.
    def marks_in(attributes)
      list_in(attributes, KEY) { |mark| valid_mark?(mark) }
    end

    # The numbers the plan wrote into the limits, as { 'conversations' => 1000 }, from the custom attributes of an account
    def plan_numbers_in(attributes)
      list_in(attributes, PLAN_NUMBERS_KEY) { |number| valid_number?(number) }
    end

    def valid_mark?(mark)
      mark == UNLIMITED || valid_number?(mark)
    end

    def valid_number?(number)
      number.is_a?(Integer) && !number.negative?
    end

    private

    def list_in(attributes, name)
      raw = attributes.to_h[name]
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(key, value), list|
        key = key.to_s
        list[key] = value if Accounts::Plans::LIMIT_KEYS.include?(key) && yield(value)
      end
    end
  end

  # modules: the modules of the plan to read the plan numbers from (default: the plan applied to the account, none without one)
  # draft  : the lists to read instead of the ones of the account (what the choices of #apply would write)
  def initialize(account, modules: nil, draft: nil)
    @account = account
    @modules = modules
    @draft = draft
  end

  # { 'agents' => 5, 'conversations' => 'unlimited' }: the limits chosen by hand as they are listed
  def marks
    @marks ||= @draft ? @draft.marks : self.class.marks_in(attributes)
  end

  # { 'conversations' => 1000 }: the numbers the plan wrote into the limits the last time (see the top of this file)
  def plan_numbers
    @plan_numbers ||= @draft ? @draft.plan_numbers : self.class.plan_numbers_in(attributes)
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

    # Read once for each limit: the settings of the installation do not change while one account is being looked at
    @global_values ||= {}
    return @global_values[name] if @global_values.key?(name)

    value = GlobalConfig.get(name)[name]
    @global_values[name] = value.blank? ? nil : value.to_i
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

  # The numbers of the plan that the limits following it hold once the plan is applied: what Accounts::ApplyPlan stores as the numbers
  # the plan wrote ({ 'conversations' => 1000 }). A limit the plan leaves alone, and one chosen by hand, is not in it.
  def following_plan_numbers
    Accounts::Plans::LIMIT_KEYS.each_with_object({}) do |key, numbers|
      number = plan_value(key)
      numbers[key] = number if !number.nil? && source(key) == :plan
    end
  end

  # Whether `choice` (:plan, :unlimited or an Integer) says what the limit already is. The forms of the screens send every row, the
  # ones nobody touched included, and those must change nothing. A number is the same when it is the same at the precision of the
  # field it was typed in (the storage is shown in gigabytes with two decimals).
  def same_choice?(key, choice)
    key = key.to_s
    case choice
    when :plan, :unlimited then source(key) == choice
    when Integer then source(key) == :custom && same_amount?(key, custom_value(key), choice)
    else false
    end
  end

  # What Account#limits, the list of the limits chosen by hand and the list of the numbers of the plan become when `choices`
  # ({ 'agents' => 5, 'storage_bytes' => :plan }) are made; the limits that are not named stay as they are, and so do the ones whose
  # choice is the one they have (#same_choice?). Nothing is written.
  def apply(choices)
    draft = Draft.new(stored_limits.dup, marks.dup, plan_numbers.dup, held_keys.dup)
    choices.each do |key, choice|
      key = key.to_s
      next unless Accounts::Plans::LIMIT_KEYS.include?(key)
      next if same_choice?(key, choice)

      apply_choice(draft, key, choice)
    end
    Result.new(limits: draft.limits, marks: draft.marks, plan_numbers: draft.plan_numbers, changes: changes_between(draft))
  end

  # What Account#limits, the list of the limits chosen by hand and the list of the numbers of the plan become when the numbers of the
  # plan as it is now are written into the limits that follow it (Accounts::SyncPlanLimits): every limit that follows the plan and has a
  # number in the plan gets it. A limit chosen by hand («своё число», «без ограничений») stays, so does one the plan has no number for,
  # so does one that an ended trial holds at 0 (that is given back by applying the plan). Nothing is written.
  def follow_current_plan
    draft = Draft.new(stored_limits.dup, marks.dup, plan_numbers.dup, held_keys.dup)
    keys = Accounts::Plans::LIMIT_KEYS.select { |key| follows_current_plan?(key) }
    keys.each { |key| follow_plan(draft, key) }
    # Only the limits that were written can have changed: a bulk run asks this of hundreds of accounts, and the general values of the
    # platform are read from the settings of the installation, one read for each limit that is looked at
    Result.new(limits: draft.limits, marks: draft.marks, plan_numbers: draft.plan_numbers, changes: changes_between(draft, keys))
  end

  # The keys of the limits an ended trial holds at 0 (the number comes back when the plan is applied, not before)
  def held_limit_keys
    Accounts::Plans::LIMIT_KEYS.select { |key| held?(key) }
  end

  # The limits chosen by hand whose number differs from the one the plan has for them: the sync leaves them as they are
  def kept_keys
    Accounts::Plans::LIMIT_KEYS.select { |key| !plan_value(key).nil? && manual?(key) && effective(key) != plan_value(key) }
  end

  private

  def follows_current_plan?(key)
    !plan_value(key).nil? && source(key) == :plan && !held?(key)
  end

  def apply_choice(draft, key, choice)
    draft.held.delete(key)
    case choice
    when :plan then follow_plan(draft, key)
    when :unlimited then choose(draft, key, UNLIMITED, Accounts::Plans.unlimited_value(key))
    else
      raise ArgumentError, "Not a choice for #{key}: #{choice.inspect}" unless choice.is_a?(Integer) && !choice.negative?

      choose(draft, key, choice, choice)
    end
  end

  # «Как в тарифе»: the number of the plan, or no number where the plan has none (the general value of the platform applies then)
  def follow_plan(draft, key)
    draft.marks.delete(key)
    plan = plan_value(key)
    if plan.nil?
      draft.limits.delete(key)
      draft.plan_numbers.delete(key)
    else
      draft.limits[key] = plan
      draft.plan_numbers[key] = plan
    end
  end

  # «Без ограничений» and «Своё число»: the mark and the number, and nothing of the plan
  def choose(draft, key, mark, number)
    draft.marks[key] = mark
    draft.limits[key] = number
    draft.plan_numbers.delete(key)
  end

  # { 'agents' => { 'from' => Position, 'to' => Position } } for the limits whose source or number differs after the choices
  # (the zero an ended trial holds on a limit nobody touched is still the platform's, not a choice)
  def changes_between(draft, keys = Accounts::Plans::LIMIT_KEYS)
    after = self.class.new(@account, modules: @modules, draft: draft)
    keys.each_with_object({}) do |key, changes|
      before = Position.new(source: source(key), value: effective(key))
      now = Position.new(source: after.source(key), value: after.effective(key))
      changes[key] = { 'from' => before, 'to' => now } if before != now
    end
  end

  def attributes
    @account.custom_attributes.to_h
  end

  def stored_limits
    @stored_limits ||= (@draft ? @draft.limits : @account.limits).to_h.transform_keys(&:to_s)
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
    held_keys.include?(key.to_s)
  end

  def held_keys
    @held_keys ||= @draft ? @draft.held : @account.trial_held_limits.keys
  end

  # The number is the one of the plan, or the one the plan wrote the last time (a number that the plan has changed since: it is
  # written over when the plan is applied). Where the plan has no number there is nothing to follow.
  def follows_plan_number?(key, value)
    plan = plan_value(key)
    !plan.nil? && (same_number?(plan, value) || same_number?(written_plan_number(key), value))
  end

  # The number the plan wrote into the limit the last time: the one kept beside the list, and, where none is kept for an account whose
  # plan was applied before the lists, the one the plans of that time wrote (LEGACY_PLAN_NUMBERS)
  def written_plan_number(key)
    plan_numbers.fetch(key) { legacy_plan_number(key) }
  end

  def legacy_plan_number(key)
    LEGACY_PLAN_NUMBERS[key] if attributes[Accounts::ApplyPlan::PLAN_KEY].present?
  end

  def same_number?(first, second)
    first.is_a?(Numeric) && second.is_a?(Numeric) && first == second
  end

  def same_amount?(key, current, chosen)
    return current == chosen unless key == 'storage_bytes'

    !current.nil? && gigabytes(current) == gigabytes(chosen)
  end

  def gigabytes(bytes)
    (BigDecimal(bytes.to_s) / 1.gigabyte).round(GIGABYTE_DECIMALS)
  end
end
