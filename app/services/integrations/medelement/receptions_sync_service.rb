# rubocop:disable Metrics/ClassLength
class Integrations::Medelement::ReceptionsSyncService
  InvalidReceptionError = Class.new(StandardError)
  IncompleteSnapshotError = Class.new(StandardError)
  MAX_RECEPTIONS_PER_REQUEST = 1000
  PROVIDER_BINDING_GRACE_PERIOD = Integrations::Medelement::SpecialistsSyncService::MISSING_GRACE_PERIOD
  PROVIDER_LAST_SEEN_AT_KEY = Integrations::Medelement::SpecialistsSyncService::LAST_SEEN_AT_KEY

  def initialize(account:, client:, configuration:, conflict_tracker: nil)
    @account = account
    @client = client
    @configuration = configuration
    @conflict_tracker = conflict_tracker
    @importer = Integrations::Medelement::AppointmentImporterService.new(
      account: account,
      conflict_tracker: conflict_tracker
    )
  end

  def perform
    @snapshot_complete = true
    resource_map = medelement_resource_map
    snapshot = build_snapshot(resource_map)
    contacts_by_patient_code = synced_contacts(snapshot)
    sync_result = sync_snapshot(snapshot, resource_map, contacts_by_patient_code)
    cleanup_missing_appointments!(sync_result[:desired_external_refs]) if snapshot_complete?
    sync_result[:skipped_pair_count] = skipped_pair_count
    log_sync_summary(sync_result)
    sync_result.except(:desired_external_refs)
  end

  private

  attr_reader :account, :client, :configuration, :conflict_tracker, :importer

  def build_snapshot(resource_map)
    snapshot = resource_map.values.flat_map do |resource|
      specialist_code = resource.custom_attributes['medelement_specialist_code']
      Array(resource.custom_attributes['medelement_cabinets']).flat_map do |cabinet|
        snapshot_for_cabinet(cabinet, specialist_code)
      end
    end

    snapshot
      .uniq { |reception| reception['RECEPTION_CODE'].to_s }
      .map { |reception| enrich_reception(reception) }
  end

  def enrich_reception(reception)
    return reception if reception['REMOVED'].to_i == 1

    reception_code = reception['RECEPTION_CODE'].to_s
    detail = client.get_reception(reception_code: reception_code, version: :v2)
    throttle!
    validate_reception_detail!(detail, reception)

    reception.merge(detail).merge(
      'PATIENT_CODE' => reception['PATIENT_CODE'].presence || detail['PROFILE_CODE']
    )
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

  def imported_appointments_in_window
    account.scheduling_appointments.where(source: 'medelement').where(starts_at: range_start..range_end)
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
      date = Time.current.in_time_zone(configuration.time_zone).to_date + configuration.receptions_days_forward + 1
      ActiveSupport::TimeZone[configuration.time_zone].local(date.year, date.month, date.day)
    end
  end

  def range_start
    @range_start ||= begin
      date = Time.current.in_time_zone(configuration.time_zone).to_date - configuration.receptions_days_back
      ActiveSupport::TimeZone[configuration.time_zone].local(date.year, date.month, date.day)
    end
  end

  def throttle!
    return unless configuration.throttle_ms.to_i.positive?

    sleep(configuration.throttle_ms.to_f / 1000)
  end

  def cleanup_missing_appointments!(desired_external_refs)
    imported_appointments_in_window.find_each do |appointment|
      next if desired_external_refs.include?(appointment.external_ref)

      Integrations::Medelement::MissingAppointmentReconciler.new(appointment: appointment).perform
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
    snapshot.filter_map { |item| item['PATIENT_CODE'].to_s if item['REMOVED'].to_i != 1 }
  end

  def skipped_reception?(reception, resource)
    reception['REMOVED'].to_i == 1 || resource.blank?
  end

  def snapshot_for_cabinet(cabinet, specialist_code)
    fetch_receptions_for_pair(
      specialist_code: specialist_code,
      company_cabinet_code: cabinet['companyCabinetCode'],
      from: range_start,
      to: range_end
    ).map do |reception|
      reception.merge(
        'specialistCode' => specialist_code,
        'COMPANY_CABINET_CODE' => reception['COMPANY_CABINET_CODE'].presence || cabinet['companyCabinetCode']
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
    snapshot.each_with_object({ desired_external_refs: Set.new, imported_count: 0, skipped_count: 0 }) do |reception, result|
      resource = resource_map[reception['specialistCode'].to_s]
      next if skipped_reception?(reception, resource)

      result[:desired_external_refs] << external_ref_for(reception)

      begin
        sync_reception(reception, resource, contacts_by_patient_code)
        result[:imported_count] += 1
      rescue InvalidReceptionError, Integrations::Medelement::ReceptionServiceRows::InvalidSnapshotError,
             ActiveRecord::RecordInvalid, Scheduling::Error => e
        result[:skipped_count] += 1
        log_skipped_reception(reception, resource, e)
      end
    end
  end

  def external_ref_for(reception)
    importer.external_ref_for(reception['RECEPTION_CODE'].to_s)
  end

  def import_context_for(reception)
    starts_at = parse_time(reception['STARTTIME'])
    ends_at = parse_time(reception['ENDTIME'])

    validate_import_context!(reception, starts_at, ends_at)

    {
      starts_at: starts_at,
      ends_at: ends_at,
      specialist_code: reception['specialistCode']
    }
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
