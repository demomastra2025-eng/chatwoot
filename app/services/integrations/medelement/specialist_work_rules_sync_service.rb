class Integrations::Medelement::SpecialistWorkRulesSyncService
  DEFAULT_WORK_RULES_SEEDED_AT_KEY = 'medelement_default_work_rules_seeded_at'.freeze
  LEGACY_DEFAULT_WORK_RULE_RANGE = (0..1440)
  DEFAULT_DAY_START_MINUTE = 9 * 60
  DEFAULT_WEEKDAY_END_MINUTE = 18 * 60
  DEFAULT_WEEKEND_END_MINUTE = 15 * 60
  RULE_ATTRIBUTES = %i[weekday start_minute end_minute active].freeze

  def initialize(account:)
    @account = account
  end

  def perform(resource)
    if resource.work_rules.exists?
      migrate_legacy_default_work_rules!(resource)
      return
    end

    replace_default_work_rules!(resource)
  end

  private

  attr_reader :account

  def desired_default_work_rules
    @desired_default_work_rules ||= [
      work_rule(0, DEFAULT_WEEKEND_END_MINUTE, active: false),
      work_rule(1, DEFAULT_WEEKDAY_END_MINUTE),
      work_rule(2, DEFAULT_WEEKDAY_END_MINUTE),
      work_rule(3, DEFAULT_WEEKDAY_END_MINUTE),
      work_rule(4, DEFAULT_WEEKDAY_END_MINUTE),
      work_rule(5, DEFAULT_WEEKDAY_END_MINUTE),
      work_rule(6, DEFAULT_WEEKEND_END_MINUTE)
    ].freeze
  end

  def work_rule(weekday, end_minute, active: true)
    { weekday: weekday, start_minute: DEFAULT_DAY_START_MINUTE, end_minute: end_minute, active: active }
  end

  def migrate_legacy_default_work_rules!(resource)
    return if resource.custom_attributes[DEFAULT_WORK_RULES_SEEDED_AT_KEY].blank?
    return unless legacy_default_work_rules?(resource.work_rules.to_a)

    replace_default_work_rules!(resource)
  end

  def legacy_default_work_rules?(rules)
    normalized_rule_tuples(rules) == normalized_rule_tuples(legacy_default_work_rules)
  end

  def legacy_default_work_rules
    (0..6).map do |weekday|
      {
        weekday: weekday,
        start_minute: LEGACY_DEFAULT_WORK_RULE_RANGE.begin,
        end_minute: LEGACY_DEFAULT_WORK_RULE_RANGE.end,
        active: true
      }
    end
  end

  def normalized_rule_tuples(rules)
    rules.map do |rule|
      RULE_ATTRIBUTES.map { |attribute| extract_rule_attribute(rule, attribute) }
    end.sort
  end

  def extract_rule_attribute(rule, attribute)
    return rule.public_send(attribute) if rule.respond_to?(attribute)

    rule.fetch(attribute)
  end

  def replace_default_work_rules!(resource)
    existing_seeded_at = resource.custom_attributes[DEFAULT_WORK_RULES_SEEDED_AT_KEY]

    Scheduling::WorkRule.transaction do
      resource.work_rules.destroy_all
      desired_default_work_rules.each { |rule| create_work_rule(resource, rule) }
      mark_seeded(resource, existing_seeded_at)
    end
  end

  def create_work_rule(resource, rule)
    resource.work_rules.create!(account: account, **rule)
  end

  def mark_seeded(resource, existing_seeded_at)
    resource.update!(
      custom_attributes: resource.custom_attributes.merge(
        DEFAULT_WORK_RULES_SEEDED_AT_KEY => existing_seeded_at.presence || Time.current.iso8601
      )
    )
  end
end
