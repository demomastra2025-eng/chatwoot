class Integrations::Medelement::ReceptionsSyncService
  InvalidReceptionError = Class.new(StandardError)
  MAX_RECEPTIONS_PER_REQUEST = 1000

  def initialize(account:, client:, configuration:)
    @account = account
    @client = client
    @configuration = configuration
    @importer = Integrations::Medelement::AppointmentImporterService.new(account: account)
  end

  def perform
    resource_map = medelement_resource_map
    snapshot = build_snapshot(resource_map)
    contacts_by_patient_code = synced_contacts(snapshot)
    sync_result = sync_snapshot(snapshot, resource_map, contacts_by_patient_code)
    cleanup_missing_appointments!(sync_result[:desired_external_refs])
    log_sync_summary(sync_result)
  end

  private

  attr_reader :account, :client, :configuration, :importer

  def build_snapshot(resource_map)
    snapshot = resource_map.values.flat_map do |resource|
      specialist_code = resource.custom_attributes['medelement_specialist_code']
      Array(resource.custom_attributes['medelement_cabinets']).flat_map do |cabinet|
        snapshot_for_cabinet(cabinet, specialist_code)
      end
    end

    snapshot.uniq { |reception| reception['RECEPTION_CODE'].to_s }
  end

  def fetch_receptions_for_pair(specialist_code:, company_cabinet_code:, from:, to:)
    receptions = client.get_receptions(
      company_cabinet_code: company_cabinet_code,
      specialist_code: specialist_code,
      begin_datetime: format_request_time(from),
      end_datetime: format_request_time(to)
    )

    throttle!
    return receptions if receptions.size < MAX_RECEPTIONS_PER_REQUEST || (to - from) <= 1.day

    split_fetch_receptions_for_pair(
      specialist_code: specialist_code,
      company_cabinet_code: company_cabinet_code,
      from: from,
      to: to
    )
  end

  def format_request_time(time)
    time.in_time_zone(configuration.time_zone).strftime('%d.%m.%Y %H:%M:%S')
  end

  def imported_appointments_in_window
    account.scheduling_appointments.where(source: 'medelement').where(starts_at: range_start..range_end)
  end

  def medelement_resources
    account.scheduling_resources.where("custom_attributes ->> 'medelement_specialist_code' IS NOT NULL")
  end

  def parse_time(value)
    ActiveSupport::TimeZone[configuration.time_zone].parse(value.to_s)
  end

  def range_end
    @range_end ||= configuration.receptions_days_forward.days.from_now.end_of_day
  end

  def range_start
    @range_start ||= configuration.receptions_days_back.days.ago.beginning_of_day
  end

  def throttle!
    return unless configuration.throttle_ms.to_i.positive?

    sleep(configuration.throttle_ms.to_f / 1000)
  end

  def cleanup_missing_appointments!(desired_external_refs)
    imported_appointments_in_window.find_each do |appointment|
      appointment.destroy! unless desired_external_refs.include?(appointment.external_ref)
    end
  end

  def medelement_resource_map
    medelement_resources.index_by { |resource| resource.custom_attributes['medelement_specialist_code'].to_s }
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
      rescue InvalidReceptionError, ActiveRecord::RecordInvalid, Scheduling::Error => e
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
    Rails.logger.warn(
      "[MEDELEMENT::RECEPTIONS_SYNC] Skipping reception #{reception['RECEPTION_CODE']} " \
      "for account=#{account.id} resource_id=#{resource.id} specialist_code=#{reception['specialistCode']} " \
      "patient_code=#{reception['PATIENT_CODE']} reason=#{error.class}: #{error.message}"
    )
  end

  def log_sync_summary(sync_result)
    return if sync_result[:skipped_count].zero?

    Rails.logger.warn(
      "[MEDELEMENT::RECEPTIONS_SYNC] Completed with skipped receptions for account=#{account.id} " \
      "imported=#{sync_result[:imported_count]} skipped=#{sync_result[:skipped_count]}"
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

    Integrations::Medelement::PatientsSyncService.new(account: account, client: client)
                                                 .sync_patient_codes(reception_patient_codes(snapshot))
  end
end
