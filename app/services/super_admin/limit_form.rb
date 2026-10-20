# frozen_string_literal: true

require 'bigdecimal'

# What the form of an account says about its limits: for every limit one of «как в тарифе», «без ограничений» and «своё число»
# (Accounts::LimitSettings), and the number of the last one. The storage is typed in gigabytes (1,5 is fine) and becomes bytes here.
#
# The forms send two groups of fields, `account[limit_choices][agents]` (plan, unlimited or custom) and `account[limit_values][agents]`
# (the number; it is read only when the choice is custom). An older form, or a script, sends the numbers alone as `account[limits][agents]`:
# a number is «своё число», a blank one is «как в тарифе», and a limit that is not named is «как в тарифе» too.
#
#   form = SuperAdmin::LimitForm.from_params(params[:account])
#   form.submitted?  # does the request say anything about the limits
#   form.valid?      # false: form.problems says which limit and why, form.message says it in words
#   form.choices     # => { 'agents' => 5, 'conversations' => :unlimited, 'storage_bytes' => :plan }
#   form.state       # => what was typed, to draw the form again: { 'agents' => { 'choice' => 'custom', 'value' => '5' } }
class SuperAdmin::LimitForm
  KEYS = Accounts::Plans::LIMIT_KEYS
  CHOICES = %w[plan unlimited custom].freeze
  # Longer than any number of ours: a text of this length is not a number somebody means
  MAX_TEXT_LENGTH = 24

  # state: { 'agents' => { 'choice' => 'custom', 'value' => '5' } } as it was typed
  attr_reader :choices, :problems, :state

  def self.from_params(account_params)
    raw = account_params.respond_to?(:to_unsafe_h) ? account_params.to_unsafe_h : account_params
    raw = {} unless raw.is_a?(Hash)
    new(map(raw['limit_choices']), map(raw['limit_values']), map(raw['limits']))
  end

  def self.map(value)
    value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
    value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
  end

  def initialize(kinds, values, numbers)
    @kinds = kinds
    @values = values
    @numbers = numbers
    @choices = {}
    @problems = {}
    @state = {}
    read
  end

  # Whether the request carries anything about the limits (a request that does not must leave them alone)
  def submitted?
    @kinds.any? || @numbers.any?
  end

  def valid?
    @problems.empty?
  end

  # What is wrong, in words (nil when nothing is)
  def message
    return if valid?

    @problems.map do |key, problem|
      problem = :invalid_storage if problem == :invalid && key == 'storage_bytes'
      I18n.t("super_admin.limits.problems.#{problem}", label: I18n.t("super_admin.limits.#{key}.label"))
    end.join(' ')
  end

  private

  def read
    @kinds.any? ? read_choices : read_numbers
  end

  # The form of the screens: only the limits it names
  def read_choices
    KEYS.each do |key|
      next unless @kinds.key?(key)

      kind = @kinds[key].to_s
      @state[key] = { 'choice' => kind, 'value' => @values[key].to_s }
      case kind
      when 'plan' then @choices[key] = :plan
      when 'unlimited' then @choices[key] = :unlimited
      when 'custom' then take_number(key, @values[key])
      else @problems[key] = :invalid_choice
      end
    end
  end

  # An older form: every limit, a blank one follows the plan
  def read_numbers
    KEYS.each do |key|
      raw = @numbers[key]
      if raw.nil? || raw.to_s.strip.empty?
        @choices[key] = :plan
        @state[key] = { 'choice' => 'plan', 'value' => '' }
      else
        @state[key] = { 'choice' => 'custom', 'value' => raw.to_s }
        take_number(key, raw)
      end
    end
  end

  def take_number(key, raw)
    number = parse(key, raw)
    case number
    when :blank, :invalid then @problems[key] = number
    else @choices[key] = Accounts::Plans.unlimited_value?(key, number) ? :unlimited : number
    end
  end

  # The number of a limit (bytes for the storage), :blank or :invalid
  def parse(key, raw)
    text = number_text(raw)
    return text if text.is_a?(Symbol)

    value = BigDecimal(text)
    return (value * 1.gigabyte).round(0).to_i if key == 'storage_bytes'

    value.frac.zero? ? value.to_i : :invalid
  end

  # What was typed as clean digits with a dot (a comma and spaces are allowed), :blank or :invalid
  def number_text(raw)
    return :invalid unless raw.nil? || raw.is_a?(String) || raw.is_a?(Numeric)

    text = raw.to_s.strip.tr(',', '.').delete(' ')
    return :blank if text.empty?

    text.length > MAX_TEXT_LENGTH || !text.match?(/\A\d+(\.\d+)?\z/) ? :invalid : text
  end
end
