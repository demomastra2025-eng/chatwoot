class Integrations::Medelement::SpecialistsSyncService
  DEFAULT_WORK_RULES_SEEDED_AT_KEY = 'medelement_default_work_rules_seeded_at'.freeze
  LEGACY_DEFAULT_WORK_RULE_START_MINUTE = 0
  LEGACY_DEFAULT_WORK_RULE_END_MINUTE = 1440
  DEFAULT_DAY_START_MINUTE = 9 * 60
  DEFAULT_WEEKDAY_END_MINUTE = 18 * 60
  DEFAULT_WEEKEND_END_MINUTE = 15 * 60

  def initialize(account:, client:, configuration:)
    @account = account
    @client = client
    @configuration = configuration
  end

  def perform
    client.get_specialists.each do |payload|
      specialist_code = payload['specialistCode'].to_s
      resource = find_resource(specialist_code) || account.scheduling_resources.new
      resource.account ||= account
      resource.name = payload['userName'].to_s
      resource.timezone = configuration.time_zone
      resource.slot_duration_min = payload['receptionTime'].to_i.clamp(5, 720)
      resource.active = payload['isSchedulePublished'].to_i == 1
      resource.custom_attributes = resource.custom_attributes.merge(resource_custom_attributes(payload, specialist_code))
      resource.save!
      sync_default_work_rules!(resource)
    end
  end

  private

  attr_reader :account, :client, :configuration

  def find_resource(specialist_code)
    account.scheduling_resources.find_by("custom_attributes ->> 'medelement_specialist_code' = ?", specialist_code.to_s)
  end

  def resource_custom_attributes(payload, specialist_code)
    {
      'medelement_cabinets' => Array(payload['cabinets']),
      'medelement_reception_time' => payload['receptionTime'],
      'medelement_schedule_published' => payload['isSchedulePublished'],
      'medelement_specialist_code' => specialist_code
    }
  end

  def desired_default_work_rules
    @desired_default_work_rules ||= [
      { weekday: 0, start_minute: DEFAULT_DAY_START_MINUTE, end_minute: DEFAULT_WEEKEND_END_MINUTE, active: false },
      { weekday: 1, start_minute: DEFAULT_DAY_START_MINUTE, end_minute: DEFAULT_WEEKDAY_END_MINUTE, active: true },
      { weekday: 2, start_minute: DEFAULT_DAY_START_MINUTE, end_minute: DEFAULT_WEEKDAY_END_MINUTE, active: true },
      { weekday: 3, start_minute: DEFAULT_DAY_START_MINUTE, end_minute: DEFAULT_WEEKDAY_END_MINUTE, active: true },
      { weekday: 4, start_minute: DEFAULT_DAY_START_MINUTE, end_minute: DEFAULT_WEEKDAY_END_MINUTE, active: true },
      { weekday: 5, start_minute: DEFAULT_DAY_START_MINUTE, end_minute: DEFAULT_WEEKDAY_END_MINUTE, active: true },
      { weekday: 6, start_minute: DEFAULT_DAY_START_MINUTE, end_minute: DEFAULT_WEEKEND_END_MINUTE, active: true }
    ].freeze
  end

  def legacy_default_work_rules?(rules)
    normalized_rule_tuples(rules) == normalized_rule_tuples(
      (0..6).map do |weekday|
        {
          weekday: weekday,
          start_minute: LEGACY_DEFAULT_WORK_RULE_START_MINUTE,
          end_minute: LEGACY_DEFAULT_WORK_RULE_END_MINUTE,
          active: true
        }
      end
    )
  end

  def normalized_rule_tuples(rules)
    rules.map do |rule|
      [
        extract_rule_attribute(rule, :weekday),
        extract_rule_attribute(rule, :start_minute),
        extract_rule_attribute(rule, :end_minute),
        extract_rule_attribute(rule, :active)
      ]
    end.sort
  end

  def extract_rule_attribute(rule, attribute)
    return rule.public_send(attribute) if rule.respond_to?(attribute)

    rule.fetch(attribute)
  end

  def sync_default_work_rules!(resource)
    if resource.work_rules.exists?
      migrate_legacy_default_work_rules!(resource)
      return
    end

    replace_default_work_rules!(resource)
  end

  def migrate_legacy_default_work_rules!(resource)
    return if resource.custom_attributes[DEFAULT_WORK_RULES_SEEDED_AT_KEY].blank?
    return unless legacy_default_work_rules?(resource.work_rules.to_a)

    replace_default_work_rules!(resource)
  end

  def replace_default_work_rules!(resource)
    existing_seeded_at = resource.custom_attributes[DEFAULT_WORK_RULES_SEEDED_AT_KEY]

    Scheduling::WorkRule.transaction do
      resource.work_rules.destroy_all

      desired_default_work_rules.each do |rule|
        resource.work_rules.create!(
          account: account,
          weekday: rule[:weekday],
          start_minute: rule[:start_minute],
          end_minute: rule[:end_minute],
          active: rule[:active]
        )
      end

      resource.update!(
        custom_attributes: resource.custom_attributes.merge(
          DEFAULT_WORK_RULES_SEEDED_AT_KEY => existing_seeded_at.presence || Time.current.iso8601
        )
      )
    end
  end
end
