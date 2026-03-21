class Integrations::Medelement::SpecialistsSyncService
  DEFAULT_WORK_RULE_START_MINUTE = 0
  DEFAULT_WORK_RULE_END_MINUTE = 1440
  DEFAULT_WORK_RULES_SEEDED_AT_KEY = 'medelement_default_work_rules_seeded_at'.freeze

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
      seed_default_work_rules!(resource)
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

  def seed_default_work_rules!(resource)
    return if resource.custom_attributes[DEFAULT_WORK_RULES_SEEDED_AT_KEY].present?
    return if resource.work_rules.exists?

    Scheduling::WorkRule.transaction do
      (0..6).each do |weekday|
        resource.work_rules.create!(
          account: account,
          weekday: weekday,
          start_minute: DEFAULT_WORK_RULE_START_MINUTE,
          end_minute: DEFAULT_WORK_RULE_END_MINUTE,
          active: true
        )
      end

      resource.update!(
        custom_attributes: resource.custom_attributes.merge(
          DEFAULT_WORK_RULES_SEEDED_AT_KEY => Time.current.iso8601
        )
      )
    end
  end
end
