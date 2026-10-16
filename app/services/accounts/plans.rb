# frozen_string_literal: true

# The registry of account plans: one base plus switchable modules, loaded from config/account_plans.yml.
# It is validated when it loads and frozen afterwards, so a typo in the file fails loudly instead of silently
# mis-configuring a clinic.
#
#   Accounts::Plans.base_features            # flags of the base plan
#   Accounts::Plans.module_keys              # => ["ai_agents", "broadcasts", ...]
#   Accounts::Plans.features_for(%w[ai_agents]) # flags that base + these modules switch on
#   Accounts::Plans.trial_features           # what a trial grants (base + the trial modules)
#
# Flag classification (base / one module / locked_on / never_enabled / internal) is described in the YAML.
# A flag that appears in two places is an error here; a flag of features.yml that appears nowhere is reported by
# #unclassified_features and is covered by a spec, so an upstream merge cannot stop the application from booting.
class Accounts::Plans
  class InvalidConfig < StandardError; end

  CONFIG_PATH = Rails.root.join('config/account_plans.yml').freeze
  BASE_KEY = 'base'
  UNLIMITED = 'unlimited'
  # Kazakhstan is a single time zone (UTC+5) since 2024-03-01; every time a person reads is shown in it.
  ASTANA_OFFSET = '+05:00'
  # The keys of Account#limits. The one list: the validation of Account#limits (Enterprise::Account::PlanUsageAndLimits
  # #validate_limit_keys) is built from it, so a key added here is accepted by the model and the plans can set it.
  LIMIT_KEYS = %w[
    inboxes agents conversations non_web_inboxes storage_bytes captain_responses captain_documents captain_tokens emails
  ].freeze

  class << self
    def current
      @current ||= from_file
    end

    def from_file(path: CONFIG_PATH, feature_names: Featurable::FEATURE_NAMES)
      new(YAML.safe_load(File.read(path)), feature_names: feature_names)
    end

    # The moment a plan is applied, as ISO 8601 with the Astana offset
    def astana_now
      Time.current.getlocal(ASTANA_OFFSET).iso8601
    end

    # "База" or "База + ИИ-агенты + Рассылки"
    def plan_label(modules)
      names = [I18n.t('super_admin.plans.base.name')] + Array(modules).map { |key| module_name(key) }
      names.join(' + ')
    end

    def module_name(key)
      I18n.t("super_admin.plans.modules.#{key}.name", default: key.to_s)
    end

    delegate :version, :base_features, :base_limits, :module_keys, :module?, :module_features, :module_limits,
             :locked_on, :never_enabled, :internal, :classified_features, :managed_features, :unclassified_features,
             :features_for, :limits_for, :normalize_modules, :known_modules, :module_for_feature,
             :trial_days, :trial_modules, :trial_features, to: :current
  end

  attr_reader :version, :base_features, :base_limits, :locked_on, :never_enabled, :internal, :trial_days, :trial_modules

  # config: the parsed YAML; feature_names: every flag the application knows (Featurable::FEATURE_NAMES)
  def initialize(config, feature_names: Featurable::FEATURE_NAMES)
    @feature_names = feature_names.to_a.map(&:to_s).freeze
    config = config.is_a?(Hash) ? config : {}

    @version = parse_version(config['version'])
    @base_features = feature_list(config.dig('base', 'features'), 'base.features')
    @base_limits = parse_limits(config.dig('base', 'limits'), 'base.limits', complete: true)
    @modules = parse_modules(config['modules'])
    @locked_on = feature_list(config['locked_on'], 'locked_on')
    @internal = feature_list(config['internal'], 'internal')
    # never_enabled may name flags that are absent from features.yml (they are removed by other branches)
    @never_enabled = name_list(config['never_enabled'], 'never_enabled').freeze
    @trial_days, @trial_modules = parse_trial(config['trial'])

    validate_unique_classification!
    freeze
  end

  def module_keys
    @modules.keys
  end

  def module?(key)
    @modules.key?(key.to_s)
  end

  def module_features(key)
    fetch_module(key)[:features]
  end

  def module_limits(key)
    fetch_module(key)[:limits]
  end

  # Every flag the plans name, wherever it is placed
  def classified_features
    all_placed_features.uniq.freeze
  end

  # Flags of features.yml that no place in the YAML names (a spec keeps this empty)
  def unclassified_features
    (@feature_names - classified_features).freeze
  end

  # Flags a plan sets (on or off) on an account; everything else is left alone. Only flags the application knows.
  def managed_features
    (@base_features + @modules.values.flat_map { |entry| entry[:features] } + @locked_on + @never_enabled)
      .uniq.intersection(@feature_names).freeze
  end

  # The flags that base + these modules switch on (locked_on included)
  def features_for(modules)
    (@base_features + normalize_modules(modules).flat_map { |key| module_features(key) } + @locked_on).uniq.freeze
  end

  # Limit values of base + these modules, for every key: a number, or nil when the plan leaves the key alone.
  # `unlimited` is resolved to ChatwootApp.max_limit. A module value (when not nil) wins over the base.
  def limits_for(modules)
    merged = @base_limits.dup
    normalize_modules(modules).each do |key|
      module_limits(key).each { |limit_key, value| merged[limit_key] = value unless value.nil? }
    end
    merged.transform_values { |value| resolve_limit(value) }.freeze
  end

  # Known module keys in registry order, without duplicates. Unknown keys raise ArgumentError.
  def normalize_modules(modules)
    requested = Array(modules).map(&:to_s).compact_blank.uniq
    unknown = requested - module_keys
    raise ArgumentError, "Unknown plan modules: #{unknown.join(', ')}" if unknown.any?

    module_keys & requested
  end

  # The keys among `modules` that exist in the registry, in registry order. Unlike #normalize_modules it never raises:
  # it reads what an account stored earlier, and a module removed from the file since then is simply ignored.
  def known_modules(modules)
    module_keys & Array(modules).map(&:to_s)
  end

  # The module that owns a flag, or nil
  def module_for_feature(feature)
    @modules.find { |_key, entry| entry[:features].include?(feature.to_s) }&.first
  end

  # What a trial grants: the base plus the trial modules
  def trial_features
    features_for(@trial_modules)
  end

  private

  def all_placed_features
    @base_features + @modules.values.flat_map { |entry| entry[:features] } + @locked_on + @never_enabled + @internal
  end

  def fetch_module(key)
    @modules.fetch(key.to_s) { raise ArgumentError, "Unknown plan module: #{key}" }
  end

  def resolve_limit(value)
    value == UNLIMITED ? ChatwootApp.max_limit.to_i : value
  end

  def parse_version(raw)
    invalid!('version must be a positive integer') unless raw.is_a?(Integer) && raw.positive?
    raw
  end

  def parse_modules(raw)
    invalid!('modules must be a map of module key => { features, limits }') unless raw.is_a?(Hash) && raw.any?

    raw.to_h { |key, entry| [key.to_s, parse_module(key.to_s, entry)] }.freeze
  end

  def parse_module(key, entry)
    invalid!("module key #{key.inspect} must be snake_case and not 'base'") unless key.match?(/\A[a-z][a-z0-9_]*\z/) && key != BASE_KEY
    invalid!("module #{key} must be a map") unless entry.is_a?(Hash)

    features = feature_list(entry['features'], "modules.#{key}.features")
    invalid!("module #{key} needs at least one feature") if features.empty?
    { features: features, limits: parse_limits(entry['limits'] || {}, "modules.#{key}.limits", complete: false) }.freeze
  end

  def parse_trial(raw)
    invalid!('trial must be a map with days and modules') unless raw.is_a?(Hash)
    days = raw['days']
    invalid!('trial.days must be a positive integer') unless days.is_a?(Integer) && days.positive?
    modules = Array(raw['modules']).map(&:to_s)
    unknown = modules - module_keys
    invalid!("trial.modules names unknown modules: #{unknown.join(', ')}") if unknown.any?
    [days, modules.freeze]
  end

  def name_list(raw, where)
    invalid!("#{where} must be a list of flag names") unless raw.nil? || raw.is_a?(Array)
    list = Array(raw).map(&:to_s)
    invalid!("#{where} has a blank flag name") if list.any?(&:blank?)
    list
  end

  # A list of flags that must all exist in features.yml
  def feature_list(raw, where)
    list = name_list(raw, where)
    unknown = list - @feature_names
    invalid!("#{where} names flags that do not exist in features.yml: #{unknown.join(', ')}") if unknown.any?
    list.freeze
  end

  def parse_limits(raw, where, complete:)
    invalid!("#{where} must be a map of limit key => number, 'unlimited' or null") unless raw.is_a?(Hash)

    limits = raw.transform_keys(&:to_s)
    check_limit_keys!(limits.keys, where, complete)
    limits.each { |key, value| check_limit_value!(value, "#{where}.#{key}") }
    limits.freeze
  end

  def check_limit_keys!(keys, where, complete)
    unknown = keys - LIMIT_KEYS
    invalid!("#{where} has unknown limit keys: #{unknown.join(', ')}") if unknown.any?
    missing = LIMIT_KEYS - keys
    invalid!("#{where} must list every limit key explicitly, missing: #{missing.join(', ')}") if complete && missing.any?
  end

  def check_limit_value!(value, where)
    return if value.nil? || value == UNLIMITED || (value.is_a?(Integer) && value >= 0)

    invalid!("#{where} must be a non-negative integer, 'unlimited' or null")
  end

  def validate_unique_classification!
    duplicated = all_placed_features.tally.select { |_name, count| count > 1 }.keys
    invalid!("flags classified more than once (or in two places): #{duplicated.join(', ')}") if duplicated.any?
  end

  def invalid!(message)
    raise InvalidConfig, "config/account_plans.yml: #{message}"
  end
end
