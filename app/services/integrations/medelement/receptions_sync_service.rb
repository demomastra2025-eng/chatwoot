# rubocop:disable Metrics/ClassLength
class Integrations::Medelement::ReceptionsSyncService
  InvalidReceptionError = Class.new(StandardError)
  IncompleteSnapshotError = Class.new(StandardError)
  MAX_RECEPTIONS_PER_REQUEST = 1000
  LIST_FINGERPRINT_KEY = 'medelement_list_fingerprint'.freeze
  DETAIL_SYNCED_AT_KEY = 'medelement_detail_synced_at'.freeze
  DETAIL_RETRY_AT_KEY = 'medelement_detail_retry_at'.freeze
  DETAIL_STATE_KEY = '_MEDELEMENT_DETAIL_STATE'.freeze
  DETAIL_RETRY_INTERVAL = 15.minutes
  REALTIME_DAYS_BACK = 1
  REALTIME_DAYS_FORWARD = 14
  WINDOW_MODES = %i[full realtime].freeze
  LIST_FINGERPRINT_FIELDS = %w[
    RECEPTION_CODE PATIENT_CODE STARTTIME ENDTIME ACTIVE REMOVED PAID NOTIFY MARKER_CODE
    SPECIALIST_CODE COMPANY_CABINET_CODE specialistCode
  ].freeze
  PROVIDER_BINDING_GRACE_PERIOD = Integrations::Medelement::SpecialistsSyncService::MISSING_GRACE_PERIOD
  PROVIDER_LAST_SEEN_AT_KEY = Integrations::Medelement::SpecialistsSyncService::LAST_SEEN_AT_KEY

  def initialize(account:, client:, configuration:, conflict_tracker: nil, window_mode: :full)
    @account = account
    @client = client
    @configuration = configuration
    @conflict_tracker = conflict_tracker
    @window_mode = window_mode.to_sym
    raise ArgumentError, "Unsupported Medelement receptions window mode: #{window_mode}" unless @window_mode.in?(WINDOW_MODES)

    @importer = Integrations::Medelement::AppointmentImporterService.new(
      account: account,
      conflict_tracker: conflict_tracker
    )
  end

  def perform
    @snapshot_complete = true
    @queried_pair_count = 0
    @appointment_snapshot_versions = load_appointment_snapshot_versions
    resource_map = medelement_resource_map
    snapshot = build_snapshot(resource_map)
    @snapshot_complete = false if queried_pair_count.zero?
    contacts_by_patient_code = synced_contacts(snapshot)
    sync_result = sync_snapshot(snapshot, resource_map, contacts_by_patient_code)
    cleanup_missing_appointments!(sync_result[:desired_external_refs]) if snapshot_complete?
    sync_result[:skipped_pair_count] = skipped_pair_count
    sync_result.merge!(window_metadata)
    log_sync_summary(sync_result)
    sync_result.except(:desired_external_refs)
  end

  private

  attr_reader :account, :client, :configuration, :conflict_tracker, :importer, :appointment_snapshot_versions, :window_mode

  def load_appointment_snapshot_versions
    account.scheduling_appointments
           .where(
             'external_ref LIKE ?',
             "#{Integrations::Medelement::AppointmentImporterService::RECEPTION_EXTERNAL_REF_PREFIX}%"
           )
           .pluck(:external_ref, :updated_at)
           .to_h
  end

  def build_snapshot(resource_map)
    snapshot = resource_map.values.flat_map do |resource|
      specialist_code = resource.custom_attributes['medelement_specialist_code']
      Array(resource.custom_attributes['medelement_cabinets']).flat_map do |cabinet|
        snapshot_for_cabinet(cabinet, specialist_code)
      end
    end

    listed_receptions = snapshot.uniq { |reception| reception['RECEPTION_CODE'].to_s }
    @appointments_by_external_ref = appointments_by_external_ref(listed_receptions)
    @detail_budget_remaining = configuration.reception_detail_budget

    listed_receptions
      .sort_by { |reception| detail_priority(reception) }
      .map { |reception| enrich_reception_if_needed(reception) }
  end

  def enrich_reception_if_needed(reception)
    fingerprint = list_fingerprint(reception)
    return reception.merge(DETAIL_STATE_KEY => 'removed') if reception['REMOVED'].to_i == 1

    appointment = appointments_by_external_ref_cache[external_ref_for(reception)]
    if detail_retry_deferred?(appointment, fingerprint)
      return reception.merge(DETAIL_STATE_KEY => 'retry_deferred', '_MEDELEMENT_LIST_FINGERPRINT' => fingerprint)
    end
    unless detail_required?(appointment, fingerprint)
      return reception.merge(DETAIL_STATE_KEY => 'fresh', '_MEDELEMENT_LIST_FINGERPRINT' => fingerprint)
    end

    return deferred_reception(reception, fingerprint) if detail_budget_remaining <= 0

    @detail_budget_remaining -= 1

    reception_code = reception['RECEPTION_CODE'].to_s
    detail = client.get_reception(reception_code: reception_code, version: :v2)
    throttle!
    validate_reception_detail!(detail, reception)

    enriched_reception(reception, detail, fingerprint)
  end

  def deferred_reception(reception, fingerprint)
    reception.merge(DETAIL_STATE_KEY => 'deferred', '_MEDELEMENT_LIST_FINGERPRINT' => fingerprint)
  end

  def enriched_reception(reception, detail, fingerprint)
    reception.merge(detail).merge(
      'PATIENT_CODE' => reception['PATIENT_CODE'].presence || detail['PROFILE_CODE'],
      DETAIL_STATE_KEY => 'fetched',
      '_MEDELEMENT_LIST_FINGERPRINT' => fingerprint,
      '_MEDELEMENT_DETAIL_SYNCED_AT' => Time.current.iso8601
    )
  end

  def appointments_by_external_ref(receptions)
    external_refs = receptions.map { |reception| external_ref_for(reception) }
    account.scheduling_appointments.where(external_ref: external_refs).index_by(&:external_ref)
  end

  def appointments_by_external_ref_cache
    @appointments_by_external_ref || {}
  end

  def detail_priority(reception)
    return 4 if reception['REMOVED'].to_i == 1

    fingerprint = list_fingerprint(reception)
    appointment = appointments_by_external_ref_cache[external_ref_for(reception)]
    return 0 unless appointment
    return 1 if appointment.custom_attributes[LIST_FINGERPRINT_KEY].to_s != fingerprint
    return 2 if detail_stale?(appointment)

    3
  end

  def detail_required?(appointment, fingerprint)
    return true unless appointment
    return true if appointment.custom_attributes[LIST_FINGERPRINT_KEY].to_s != fingerprint

    detail_stale?(appointment)
  end

  def detail_stale?(appointment)
    synced_at = Time.zone.parse(appointment.custom_attributes[DETAIL_SYNCED_AT_KEY].to_s)
    synced_at.blank? || synced_at < configuration.reception_detail_refresh_interval.ago
  rescue ArgumentError, TypeError
    true
  end

  def detail_retry_deferred?(appointment, fingerprint)
    return false unless appointment
    return false if appointment.custom_attributes[LIST_FINGERPRINT_KEY].to_s != fingerprint

    retry_at = Time.zone.parse(appointment.custom_attributes[DETAIL_RETRY_AT_KEY].to_s)
    retry_at.present? && retry_at > Time.current
  rescue ArgumentError, TypeError
    false
  end

  def list_fingerprint(reception)
    payload = reception.slice(*LIST_FINGERPRINT_FIELDS).transform_values(&:to_s)
    Digest::SHA256.hexdigest(payload.sort.to_h.to_json)
  end

  def detail_budget_remaining
    @detail_budget_remaining.to_i
  end

  def validate_reception_detail!(detail, listed_reception)
    valid = detail.is_a?(Hash) &&
            detail['RECEPTION_CODE'].to_s == listed_reception['RECEPTION_CODE'].to_s &&
            detail['SERVICES'].is_a?(Array) &&
            detail_patient_code(detail).present? &&
            detail_patient_code(detail) == listed_reception['PATIENT_CODE'].to_s
    raise IncompleteSnapshotError, "Medelement reception detail is incomplete for account=#{account.id}" unless valid

    Integrations::Medelement::ProviderScope.validate_write!(
      detail,
      organization_id: configuration.organization_id
    )
  rescue Integrations::Medelement::ProviderScope::MismatchError => e
    raise IncompleteSnapshotError, "Medelement reception detail scope is invalid for account=#{account.id}: #{e.message}"
  end

  def detail_patient_code(detail)
    (detail['PROFILE_CODE'] || detail['PATIENT_CODE']).to_s
  end

  def fetch_receptions_for_pair(specialist_code:, company_cabinet_code:, from:, to:)
    receptions = client.get_receptions(
      company_cabinet_code: company_cabinet_code,
      specialist_code: specialist_code,
      begin_datetime: from.in_time_zone(configuration.time_zone).strftime('%d.%m.%Y %H:%M:%S'),
      end_datetime: to.in_time_zone(configuration.time_zone).strftime('%d.%m.%Y %H:%M:%S')
    )

    throttle!
    return receptions if receptions.size < MAX_RECEPTIONS_PER_REQUEST

    raise IncompleteSnapshotError, "Medelement reception snapshot is saturated for account=#{account.id}" if (to - from) <= 1.day

    split_fetch_receptions_for_pair(
      specialist_code: specialist_code,
      company_cabinet_code: company_cabinet_code,
      from: from,
      to: to
    )
  end

  def provider_backed_appointments_in_window
    scope = account.scheduling_appointments.where(starts_at: range_start..range_end)
    imported = scope.where(source: 'medelement')
    trusted_outbound = scope
                       .where(id: succeeded_outbound_appointment_ids)
                       .where("custom_attributes ->> 'medelement_provider_sync_status' = 'succeeded'")
                       .where(
                         "external_ref = :prefix || (custom_attributes ->> 'medelement_reception_code')",
                         prefix: Integrations::Medelement::AppointmentImporterService::RECEPTION_EXTERNAL_REF_PREFIX
                       )

    imported.or(trusted_outbound)
  end

  def succeeded_outbound_appointment_ids
    Integrations::Medelement::ProviderCommand
      .where(account_id: account.id, operation: 'create_reception', status: 'succeeded')
      .select(:appointment_id)
  end

  def medelement_resources
    account.scheduling_resources.available_for_scheduling
           .where("custom_attributes ->> 'medelement_specialist_code' IS NOT NULL")
  end

  def parse_time(value)
    ActiveSupport::TimeZone[configuration.time_zone].parse(value.to_s)
  end

  def range_end
    @range_end ||= begin
      date = Time.current.in_time_zone(configuration.time_zone).to_date + range_days_forward + 1
      ActiveSupport::TimeZone[configuration.time_zone].local(date.year, date.month, date.day)
    end
  end

  def range_start
    @range_start ||= begin
      date = Time.current.in_time_zone(configuration.time_zone).to_date - range_days_back
      ActiveSupport::TimeZone[configuration.time_zone].local(date.year, date.month, date.day)
    end
  end

  def range_days_back
    return configuration.receptions_days_back if window_mode == :full

    [configuration.receptions_days_back, REALTIME_DAYS_BACK].min
  end

  def range_days_forward
    return configuration.receptions_days_forward if window_mode == :full

    [configuration.receptions_days_forward, REALTIME_DAYS_FORWARD].min
  end

  def window_metadata
    {
      window_mode: window_mode.to_s,
      window_start: range_start.iso8601,
      window_end: range_end.iso8601
    }
  end

  def throttle!
    return unless configuration.throttle_ms.to_i.positive?

    sleep(configuration.throttle_ms.to_f / 1000)
  end

  def cleanup_missing_appointments!(desired_external_refs)
    provider_backed_appointments_in_window.find_each do |appointment|
      next if appointment.status == 'cancelled'
      next if desired_external_refs.include?(appointment.external_ref)

      Integrations::Medelement::MissingAppointmentReconciler.new(
        appointment: appointment,
        snapshot_version: appointment_snapshot_versions[appointment.external_ref]
      ).perform
    end
  end

  def medelement_resource_map
    medelement_resources.each_with_object({}) do |resource, result|
      if stale_provider_binding?(resource)
        skip_stale_provider_bindings!(resource)
        next
      end

      result[resource.custom_attributes['medelement_specialist_code'].to_s] = resource
    end
  end

  def reception_patient_codes(snapshot)
    snapshot.filter_map do |item|
      item['PATIENT_CODE'].to_s if item[DETAIL_STATE_KEY] == 'fetched' && item['REMOVED'].to_i != 1
    end
  end

  def skipped_reception?(reception, resource)
    reception['REMOVED'].to_i == 1 || resource.blank?
  end

  def snapshot_for_cabinet(cabinet, specialist_code)
    company_cabinet_code = cabinet['companyCabinetCode']
    if specialist_code.blank? || company_cabinet_code.blank?
      @snapshot_complete = false
      return []
    end

    @queried_pair_count += 1
    fetch_receptions_for_pair(
      specialist_code: specialist_code,
      company_cabinet_code: company_cabinet_code,
      from: range_start,
      to: range_end
    ).map do |reception|
      reception.merge(
        'specialistCode' => specialist_code,
        'COMPANY_CABINET_CODE' => reception['COMPANY_CABINET_CODE'].presence || company_cabinet_code
      )
    end
  end

  def stale_provider_binding?(resource)
    value = resource.custom_attributes[PROVIDER_LAST_SEEN_AT_KEY].to_s
    return false if value.blank?

    last_seen_at = Time.iso8601(value)
    last_seen_at < Time.current - PROVIDER_BINDING_GRACE_PERIOD
  rescue ArgumentError
    true
  end

  def skip_stale_provider_bindings!(resource)
    @snapshot_complete = false
    specialist_code = resource.custom_attributes['medelement_specialist_code']
    Array(resource.custom_attributes['medelement_cabinets']).each do |cabinet|
      skip_stale_provider_binding!(resource, specialist_code, cabinet)
    end
  end

  def skip_stale_provider_binding!(resource, specialist_code, cabinet)
    @skipped_pair_count = skipped_pair_count + 1
    entity_key = [specialist_code, cabinet['companyCabinetCode']].join(':')
    conflict_tracker&.record!(
      phase: 'receptions',
      entity_type: 'specialist_cabinet',
      conflict_type: 'stale_provider_binding',
      entity_key: entity_key,
      severity: 'error',
      details: stale_provider_binding_details(resource, specialist_code, cabinet)
    )
    Rails.logger.warn(
      "[MEDELEMENT::RECEPTIONS_SYNC] Skipping stale provider binding for account=#{account.id} " \
      "resource_id=#{resource.id} entity_digest=#{Integrations::Medelement::ErrorSanitizer.digest(entity_key)}"
    )
  end

  def stale_provider_binding_details(resource, specialist_code, cabinet)
    {
      reason: 'Specialist/cabinet binding was not observed within the provider grace period',
      resource_id: resource.id,
      specialist_code: specialist_code,
      company_cabinet_code: cabinet['companyCabinetCode'],
      provider_last_seen_at: resource.custom_attributes[PROVIDER_LAST_SEEN_AT_KEY]
    }
  end

  def skipped_pair_count
    @skipped_pair_count.to_i
  end

  def queried_pair_count
    @queried_pair_count.to_i
  end

  def snapshot_complete?
    @snapshot_complete
  end

  def split_fetch_receptions_for_pair(specialist_code:, company_cabinet_code:, from:, to:)
    midpoint = from + ((to - from) / 2)
    receptions = fetch_receptions_for_pair(
      specialist_code: specialist_code,
      company_cabinet_code: company_cabinet_code,
      from: from,
      to: midpoint
    )
    receptions += fetch_receptions_for_pair(
      specialist_code: specialist_code,
      company_cabinet_code: company_cabinet_code,
      from: midpoint,
      to: to
    )
    receptions.uniq { |reception| reception['RECEPTION_CODE'].to_s }
  end

  def sync_reception(reception, resource, contacts_by_patient_code)
    import_context = import_context_for(reception)

    importer.upsert!(
      resource: resource,
      contact: contacts_by_patient_code[reception['PATIENT_CODE'].to_s],
      reception: reception,
      import_context: import_context
    )
  end

  def sync_snapshot(snapshot, resource_map, contacts_by_patient_code)
    snapshot.each_with_object(
      {
        desired_external_refs: Set.new,
        imported_count: 0,
        skipped_count: 0,
        detail_skipped_count: 0,
        detail_deferred_count: 0,
        detail_retry_deferred_count: 0
      }
    ) do |reception, result|
      resource = resource_map[reception['specialistCode'].to_s]
      next if skipped_reception?(reception, resource)

      result[:desired_external_refs] << external_ref_for(reception)
      sync_snapshot_reception(reception, resource, contacts_by_patient_code, result)
    end
  end

  def sync_snapshot_reception(reception, resource, contacts_by_patient_code, result)
    if reception[DETAIL_STATE_KEY] != 'fetched'
      counter = detail_state_counter(reception[DETAIL_STATE_KEY])
      result[counter] += 1
      return
    end

    sync_reception(reception, resource, contacts_by_patient_code)
    result[:imported_count] += 1
  rescue Integrations::Medelement::AppointmentSnapshotGuard::StaleSnapshotError => e
    result[:skipped_count] += 1
    log_stale_snapshot(reception, resource, e)
  rescue InvalidReceptionError, Integrations::Medelement::ReceptionServiceRows::InvalidSnapshotError,
         ActiveRecord::RecordInvalid, Scheduling::Error => e
    result[:skipped_count] += 1
    log_skipped_reception(reception, resource, e)
    defer_detail_retry!(reception)
  end

  def detail_state_counter(state)
    return :detail_deferred_count if state == 'deferred'
    return :detail_retry_deferred_count if state == 'retry_deferred'

    :detail_skipped_count
  end

  def defer_detail_retry!(reception)
    appointment = appointments_by_external_ref_cache[external_ref_for(reception)]
    return unless appointment

    appointment.with_lock do
      appointment.reload
      attributes = appointment.custom_attributes.merge(
        LIST_FINGERPRINT_KEY => reception['_MEDELEMENT_LIST_FINGERPRINT'],
        DETAIL_RETRY_AT_KEY => DETAIL_RETRY_INTERVAL.from_now.iso8601
      )
      # The rejection may be caused by an existing invalid association, so persist only isolated reconciliation metadata.
      # rubocop:disable Rails/SkipsModelValidations
      appointment.update_column(:custom_attributes, attributes)
      # rubocop:enable Rails/SkipsModelValidations
    end
  end

  def external_ref_for(reception)
    importer.external_ref_for(reception['RECEPTION_CODE'].to_s)
  end

  def import_context_for(reception)
    starts_at = parse_time(reception['STARTTIME'])
    ends_at = parse_time(reception['ENDTIME'])
    external_ref = external_ref_for(reception)

    validate_import_context!(reception, starts_at, ends_at)

    {
      starts_at: starts_at,
      ends_at: ends_at,
      specialist_code: reception['specialistCode'],
      snapshot_version: {
        exists: appointment_snapshot_versions.key?(external_ref),
        updated_at: appointment_snapshot_versions[external_ref]
      },
      list_fingerprint: reception['_MEDELEMENT_LIST_FINGERPRINT'],
      detail_synced_at: reception['_MEDELEMENT_DETAIL_SYNCED_AT']
    }
  end

  def log_stale_snapshot(reception, resource, error)
    entity_key = reception['RECEPTION_CODE'].to_s
    conflict_tracker&.record!(
      phase: 'receptions',
      entity_type: 'reception',
      conflict_type: 'stale_snapshot',
      entity_key: entity_key,
      severity: 'warning',
      details: reception_conflict_details(reception, resource, error)
    )
    Rails.logger.warn(
      "[MEDELEMENT::RECEPTIONS_SYNC] Skipping stale reception snapshot for account=#{account.id} " \
      "resource_id=#{resource.id} entity_digest=#{Integrations::Medelement::ErrorSanitizer.digest(entity_key)}"
    )
  end

  def log_skipped_reception(reception, resource, error)
    entity_key = reception['RECEPTION_CODE'].presence || [reception['specialistCode'], reception['STARTTIME']].join(':')
    conflict_tracker&.record!(
      phase: 'receptions',
      entity_type: 'reception',
      conflict_type: 'invalid_reception',
      entity_key: entity_key,
      severity: 'error',
      details: reception_conflict_details(reception, resource, error)
    )
    Rails.logger.warn(
      "[MEDELEMENT::RECEPTIONS_SYNC] Skipping reception for account=#{account.id} " \
      "resource_id=#{resource.id} entity_digest=#{Integrations::Medelement::ErrorSanitizer.digest(entity_key)} " \
      "reason=#{error.class}"
    )
  end

  def reception_time_epoch(value)
    parse_time(value)&.to_i
  rescue ArgumentError
    nil
  end

  def reception_conflict_details(reception, resource, error)
    {
      reason: error.message,
      reception_code: reception['RECEPTION_CODE'].presence,
      resource_id: resource.id,
      specialist_code: reception['specialistCode'].presence,
      patient_code: reception['PATIENT_CODE'].presence,
      starts_at_unix: reception_time_epoch(reception['STARTTIME']),
      ends_at_unix: reception_time_epoch(reception['ENDTIME'])
    }.compact
  end

  def log_sync_summary(sync_result)
    return if sync_result[:skipped_count].zero? && sync_result[:skipped_pair_count].zero?

    Rails.logger.warn(
      "[MEDELEMENT::RECEPTIONS_SYNC] Completed with skipped receptions for account=#{account.id} " \
      "imported=#{sync_result[:imported_count]} skipped=#{sync_result[:skipped_count]} " \
      "skipped_pairs=#{sync_result[:skipped_pair_count]}"
    )
  end

  def validate_import_context!(reception, starts_at, ends_at)
    reception_code = reception['RECEPTION_CODE'].to_s

    raise InvalidReceptionError, 'missing reception code' if reception_code.blank?
    raise InvalidReceptionError, 'missing start time' if starts_at.blank?
    raise InvalidReceptionError, 'missing end time' if ends_at.blank?
    return if ends_at > starts_at

    raise InvalidReceptionError, "invalid time range #{reception['STARTTIME']}..#{reception['ENDTIME']}"
  end

  def synced_contacts(snapshot)
    return {} unless configuration.sync_patients?

    Integrations::Medelement::PatientsSyncService.new(
      account: account,
      client: client,
      conflict_tracker: conflict_tracker,
      organization_id: configuration.organization_id
    )
                                                 .sync_patient_codes(reception_patient_codes(snapshot))
  end
end
# rubocop:enable Metrics/ClassLength
