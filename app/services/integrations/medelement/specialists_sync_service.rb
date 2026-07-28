class Integrations::Medelement::SpecialistsSyncService
  DEFAULT_WORK_RULES_SEEDED_AT_KEY = 'medelement_default_work_rules_seeded_at'.freeze
  LAST_SEEN_AT_KEY = 'medelement_last_seen_at'.freeze
  SPECIALIST_CODE_KEY = 'medelement_specialist_code'.freeze
  MISSING_GRACE_PERIOD = 7.days
  LEGACY_DEFAULT_WORK_RULE_START_MINUTE = 0
  LEGACY_DEFAULT_WORK_RULE_END_MINUTE = 1440
  DEFAULT_DAY_START_MINUTE = 9 * 60
  DEFAULT_WEEKDAY_END_MINUTE = 18 * 60
  DEFAULT_WEEKEND_END_MINUTE = 15 * 60

  def initialize(account:, client:, configuration:, source: nil, now: Time.current)
    @account = account
    @client = client
    @configuration = configuration
    @specialists = source&.fetch(:specialists, nil)
    @cabinets_by_code = Array(source&.fetch(:cabinets, nil)).index_by do |cabinet|
      normalized_payload(cabinet)['companyCabinetCode'].to_s
    end
    @now = now
  end

  def perform
    seen_codes = Array(specialists || client.specialists).filter_map do |payload|
      sync_specialist!(normalized_payload(payload))
    end
    deactivate_stale_specialists!(seen_codes)

    { imported_count: seen_codes.size }
  end

  private

  attr_reader :account, :cabinets_by_code, :client, :configuration, :now, :specialists

  def sync_specialist!(payload)
    specialist_code = payload['specialistCode'].to_s
    specialist_name = payload['userName'].presence || payload['fullName'].presence
    return log_skipped_specialist('missing_specialist_code') if specialist_code.blank?
    return log_skipped_specialist('missing_name', specialist_code) if specialist_name.blank?

    resource = find_resource(specialist_code) || account.scheduling_resources.new
    resource.assign_attributes(specialist_attributes(resource, payload, specialist_code, specialist_name))
    resource.save!
    sync_default_work_rules!(resource)
    specialist_code
  end

  def specialist_attributes(resource, payload, specialist_code, specialist_name)
    attributes = {
      account: resource.account || account,
      name: specialist_name,
      timezone: payload['timezone'].presence || configuration.time_zone,
      slot_duration_min: slot_duration(payload, resource),
      active: resource.deleted_from_scheduling? ? false : specialist_active?(payload),
      custom_attributes: resource.custom_attributes.merge(resource_custom_attributes(payload, specialist_code))
    }
    attributes[:specialty] = payload['specialty'] if payload['specialty'].present?
    attributes
  end

  def find_resource(specialist_code)
    account.scheduling_resources.find_by("custom_attributes ->> '#{SPECIALIST_CODE_KEY}' = ?", specialist_code.to_s)
  end

  def resource_custom_attributes(payload, specialist_code)
    {
      'medelement_cabinets' => cabinets_for(payload),
      LAST_SEEN_AT_KEY => now.iso8601,
      'medelement_reception_time' => payload['receptionTime'],
      'medelement_schedule_published' => schedule_published_value(payload),
      SPECIALIST_CODE_KEY => specialist_code
    }
  end

  def cabinets_for(payload)
    return Array(payload['cabinets']).map { |cabinet| normalized_payload(cabinet) } if payload.key?('cabinets')

    Array(payload['cabinetCodes']).filter_map { |code| cabinets_by_code[code.to_s] }
  end

  def deactivate_stale_specialists!(seen_codes)
    medelement_resources.find_each do |resource|
      next if seen_codes.include?(resource.custom_attributes[SPECIALIST_CODE_KEY])
      next unless stale?(resource.custom_attributes[LAST_SEEN_AT_KEY])

      resource.update!(active: false)
    end
  end

  def log_skipped_specialist(reason, specialist_code = nil)
    Rails.logger.warn(
      "[MEDELEMENT::SPECIALISTS_SYNC] Skipping specialist for account=#{account.id} " \
      "specialist_code=#{specialist_code.presence || 'missing'} reason=#{reason}"
    )
    nil
  end

  def medelement_resources
    account.scheduling_resources.where("custom_attributes ->> '#{SPECIALIST_CODE_KEY}' IS NOT NULL")
  end

  def normalized_payload(payload)
    payload.to_h.with_indifferent_access
  end

  def schedule_published_value(payload)
    key = %w[isSchedulePublished schedulePublished active].find { |candidate| payload.key?(candidate) }
    payload[key] if key
  end

  def slot_duration(payload, resource)
    value = payload['slotDurationMin'].presence || payload['receptionTime'].presence || resource.slot_duration_min
    value.to_i.clamp(5, 720)
  end

  def specialist_active?(payload)
    value = schedule_published_value(payload)
    return true if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def stale?(last_seen_at)
    return false if last_seen_at.blank?

    Time.iso8601(last_seen_at) < now - MISSING_GRACE_PERIOD
  rescue ArgumentError
    false
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
