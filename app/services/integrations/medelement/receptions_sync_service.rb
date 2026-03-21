class Integrations::Medelement::ReceptionsSyncService
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
    desired_external_refs = sync_snapshot(snapshot, resource_map, contacts_by_patient_code)
    cleanup_missing_appointments!(desired_external_refs)
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
    importer.upsert!(
      resource: resource,
      contact: contacts_by_patient_code[reception['PATIENT_CODE'].to_s],
      reception: reception,
      import_context: {
        starts_at: parse_time(reception['STARTTIME']),
        ends_at: parse_time(reception['ENDTIME']),
        specialist_code: reception['specialistCode']
      }
    )
  end

  def sync_snapshot(snapshot, resource_map, contacts_by_patient_code)
    snapshot.each_with_object(Set.new) do |reception, desired_external_refs|
      resource = resource_map[reception['specialistCode'].to_s]
      next if skipped_reception?(reception, resource)

      sync_reception(reception, resource, contacts_by_patient_code)
      desired_external_refs << importer.external_ref_for(reception['RECEPTION_CODE'])
    end
  end

  def synced_contacts(snapshot)
    return {} unless configuration.sync_patients?

    Integrations::Medelement::PatientsSyncService.new(account: account, client: client)
                                                 .sync_patient_codes(reception_patient_codes(snapshot))
  end
end
