# frozen_string_literal: true

# Compiles values only; it never reads a workspace, writes a payer, or grants a feature.
# An unset catalogue limit needs an explicit resolved default; nil is an explicit unlimited default.
class Billing::PlanSnapshot
  VERSION = 1
  SOURCE = 'account_plans'
  PLAN_KEYS = %w[schema_version source catalog_version tariff modules features limits limit_sources].freeze
  PRICE_KEYS = %w[schema_version source catalog_version tariff currency pricing].freeze
  LIMIT_SOURCES = %w[plan default custom unlimited].freeze

  def self.compile(tariff:, overrides: {}, defaults: {})
    new(tariff: tariff, overrides: overrides, defaults: defaults).compile
  end

  def self.valid?(plan, price)
    return false unless exact_keys?(plan, PLAN_KEYS) && exact_keys?(price, PRICE_KEYS)
    return false unless valid_headers?(plan, price) && valid_limits?(plan)
    return false unless %w[modules features].all? { |key| string_list?(plan[key]) }

    valid_pricing?(price)
  end

  def self.valid_pricing?(price)
    pricing = price['pricing']
    exact_keys?(pricing, Accounts::Plans::PRICING_KEYS) && pricing['custom'] == false &&
      pricing.except('custom').values.all? { |value| nonnegative_or_nil?(value) } &&
      pricing['monthly_kzt'].is_a?(Integer)
  end
  private_class_method :valid_pricing?

  def self.valid_headers?(plan, price)
    [plan, price].all? { |value| valid_header?(value) } && price['currency'] == 'KZT' &&
      plan.values_at('catalog_version', 'tariff') == price.values_at('catalog_version', 'tariff')
  end
  private_class_method :valid_headers?

  def self.valid_header?(value)
    value['schema_version'] == VERSION && value['source'] == SOURCE &&
      value['catalog_version'].is_a?(Integer) && value['catalog_version'].positive? &&
      value['tariff'].is_a?(String) && value['tariff'].present?
  end
  private_class_method :valid_header?

  def self.valid_limits?(plan)
    limits = plan['limits']
    sources = plan['limit_sources']
    exact_keys?(limits, Accounts::Plans::LIMIT_KEYS) && exact_keys?(sources, Accounts::Plans::LIMIT_KEYS) &&
      limits.values.all? { |value| nonnegative_or_nil?(value) } &&
      sources.values.all? { |value| LIMIT_SOURCES.include?(value) }
  end
  private_class_method :valid_limits?

  def self.exact_keys?(value, keys)
    value.is_a?(Hash) && value.keys.sort == keys.sort
  end
  private_class_method :exact_keys?

  def self.string_list?(value)
    value.is_a?(Array) && value.all?(String)
  end
  private_class_method :string_list?

  def self.nonnegative_or_nil?(value)
    value.nil? || (value.is_a?(Integer) && value >= 0)
  end
  private_class_method :nonnegative_or_nil?

  def initialize(tariff:, overrides:, defaults:)
    @plans = Accounts::Plans.current
    @tariff = @plans.known_tariff(tariff)
    @overrides = overrides.stringify_keys
    @defaults = defaults.stringify_keys
    raise ArgumentError, 'unknown limit keys' if ((@overrides.keys | @defaults.keys) - Accounts::Plans::LIMIT_KEYS).any?
    raise ArgumentError, 'custom monetary terms must be resolved explicitly before adoption' if @plans.tariff_pricing(@tariff)['custom']
  end

  def compile
    limits, sources = compile_limits
    header = { 'schema_version' => VERSION, 'source' => SOURCE, 'catalog_version' => @plans.version, 'tariff' => @tariff }
    plan = header.merge('modules' => @plans.tariff_modules(@tariff).dup,
                        'features' => @plans.features_for(@plans.tariff_modules(@tariff)).dup, 'limits' => limits, 'limit_sources' => sources)
    price = header.merge('currency' => 'KZT', 'pricing' => Accounts::Plans::PRICING_KEYS.index_with { |key| @plans.tariff_pricing(@tariff)[key] })
    price['pricing']['custom'] = false
    raise ArgumentError, 'invalid compiled contract' unless self.class.valid?(plan, price)

    { plan_snapshot: plan, price_snapshot: price }
  end

  private

  def compile_limits
    limits = @plans.limits_for(@plans.tariff_modules(@tariff), tariff: @tariff).dup
    sources = limits.keys.index_with { 'plan' }
    limits.each_key do |key|
      if @overrides.key?(key)
        override_limit(limits, sources, key)
      elsif limits[key].nil?
        raise ArgumentError, "unresolved default: #{key}" unless @defaults.key?(key)

        limits[key] = @defaults[key]
        sources[key] = 'default'
      end
    end
    [limits, sources]
  end

  def override_limit(limits, sources, key)
    value = @overrides[key]
    raise ArgumentError, "invalid override: #{key}" unless Accounts::LimitSettings.valid_mark?(value)

    unlimited = value == Accounts::Plans::UNLIMITED
    limits[key] = unlimited ? Accounts::Plans.unlimited_value(key) : value
    sources[key] = unlimited ? 'unlimited' : 'custom'
  end
end
