class Integrations::Medelement::SpecialistsSyncService
  LAST_SEEN_AT_KEY = 'medelement_last_seen_at'.freeze
  SPECIALIST_CODE_KEY = 'medelement_specialist_code'.freeze
  MISSING_GRACE_PERIOD = 7.days

  def initialize(account:, client:, configuration:, **options)
    @account = account
    @client = client
    @configuration = configuration
    source = options[:source]
    @specialists = source&.fetch(:specialists, nil)
    @source_cabinets = Array(source&.fetch(:cabinets, nil))
    @now = options.fetch(:now, Time.current)
    @conflict_tracker = options[:conflict_tracker]
  end

  def perform
    rows = specialists || Integrations::Medelement::SpecialistsSnapshotService.new(client: client).perform
    @cabinet_resolver = Integrations::Medelement::CabinetSnapshotResolver.new(
      account: account,
      source_cabinets: source_cabinets,
      specialist_rows: rows,
      conflict_tracker: conflict_tracker
    )
    seen_codes = Array(rows).filter_map do |payload|
      sync_specialist!(normalized_payload(payload))
    end
    # Live provider responses have no total/completeness marker; only validated catalog imports pass client: nil.
    deactivate_stale_specialists!(seen_codes) if client.nil?

    { imported_count: seen_codes.size, skipped_count: Array(rows).size - seen_codes.size }
  end

  private

  attr_reader :account, :cabinet_resolver, :client, :configuration, :conflict_tracker, :now, :source_cabinets,
              :specialists

  def sync_specialist!(payload)
    specialist_code = payload['specialistCode'].to_s
    specialist_name = payload['userName'].presence || payload['fullName'].presence
    return log_skipped_specialist('missing_specialist_code', payload: payload) if specialist_code.blank?
    return log_skipped_specialist('missing_name', specialist_code, payload: payload) if specialist_name.blank?

    resource = find_resource(specialist_code) || account.scheduling_resources.new
    resource.assign_attributes(specialist_attributes(resource, payload, specialist_code, specialist_name))
    resource.save!
    work_rules_sync_service.perform(resource)
    specialist_code
  end

  def specialist_attributes(resource, payload, specialist_code, specialist_name)
    attributes = {
      account: resource.account || account,
      name: specialist_name,
      timezone: payload['timezone'].presence || configuration.time_zone,
      slot_duration_min: slot_duration(payload, resource),
      active: resource.deleted_from_scheduling? ? false : specialist_active?(payload),
      custom_attributes: resource.custom_attributes.merge(resource_custom_attributes(resource, payload, specialist_code))
    }
    attributes[:specialty] = payload['specialty'] if payload['specialty'].present?
    attributes
  end

  def find_resource(specialist_code)
    account.scheduling_resources.find_by("custom_attributes ->> '#{SPECIALIST_CODE_KEY}' = ?", specialist_code.to_s)
  end

  def resource_custom_attributes(resource, payload, specialist_code)
    {
      'medelement_cabinets' => cabinet_resolver.cabinets_for(resource, payload),
      LAST_SEEN_AT_KEY => now.iso8601,
      'medelement_reception_time' => payload['receptionTime'],
      'medelement_schedule_published' => schedule_published_value(payload),
      SPECIALIST_CODE_KEY => specialist_code
    }
  end

  def deactivate_stale_specialists!(seen_codes)
    medelement_resources.find_each do |resource|
      next if seen_codes.include?(resource.custom_attributes[SPECIALIST_CODE_KEY])
      next unless stale?(resource.custom_attributes[LAST_SEEN_AT_KEY])

      resource.update!(active: false)
    end
  end

  def log_skipped_specialist(reason, specialist_code = nil, payload: {})
    entity_key = specialist_code.presence || "missing:#{reason}"
    conflict_tracker&.record!(
      phase: 'specialists',
      entity_type: 'specialist',
      conflict_type: 'invalid_specialist',
      entity_key: entity_key,
      severity: 'error',
      details: {
        reason: reason,
        specialist_code: specialist_code,
        specialist_name: payload['userName'].presence || payload['fullName'].presence,
        specialty: payload['specialty'].presence
      }.compact
    )
    Rails.logger.warn(
      "[MEDELEMENT::SPECIALISTS_SYNC] Skipping specialist for account=#{account.id} " \
      "entity_digest=#{Integrations::Medelement::ErrorSanitizer.digest(entity_key)} reason=#{reason}"
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

  def work_rules_sync_service
    @work_rules_sync_service ||= Integrations::Medelement::SpecialistWorkRulesSyncService.new(account: account)
  end
end
