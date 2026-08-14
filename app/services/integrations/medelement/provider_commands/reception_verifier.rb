class Integrations::Medelement::ProviderCommands::ReceptionVerifier
  def initialize(command:, provider_patient_code: nil)
    @command = command
    @provider_patient_code = provider_patient_code.presence || snapshot['provider_patient_code'].presence ||
                             command.provider_patient_code
  end

  def destination_match?(reception, expected_reception_code: nil)
    active?(reception) && destination_reference_matches?(reception, expected_reception_code) &&
      patient_matches?(reception) && destination_matches?(reception) && destination_time_matches?(reception) &&
      services_match?(reception)
  end

  def moved_match?(reception)
    active?(reception) && source_identity_matches?(reception) && destination_time_matches?(reception) &&
      services_match?(reception)
  end

  def removed_match?(reception)
    removed?(reception) && source_identity_matches?(reception) && source_time_matches?(reception) &&
      services_match?(reception)
  end

  def reference_matches?(reception, expected_code: source_reception_code)
    reception.is_a?(Hash) && reception['RECEPTION_CODE'].present? &&
      reception['RECEPTION_CODE'].to_s == expected_code.to_s
  end

  def patient_matches?(reception)
    remote_patient_code = reception['PROFILE_CODE'].presence || reception['PATIENT_CODE'].presence
    provider_patient_code.present? && remote_patient_code.to_s == provider_patient_code.to_s
  end

  def specialist_matches?(reception)
    reception['SPECIALIST_CODE'].present? && reception['SPECIALIST_CODE'].to_s == specialist_code.to_s
  end

  def cabinet_matches?(reception)
    reception['COMPANY_CABINET_CODE'].present? &&
      reception['COMPANY_CABINET_CODE'].to_s == snapshot.fetch('company_cabinet_code').to_s
  end

  def source_time_matches?(reception)
    reception_time_matches?(reception, start_key: 'source_starts_at', end_key: 'source_ends_at')
  end

  def destination_time_matches?(reception)
    reception_time_matches?(reception, start_key: 'destination_starts_at', end_key: 'destination_ends_at')
  end

  def services_match?(reception)
    rows = Integrations::Medelement::ReceptionServiceRows.active(reception)
    actual_codes = rows.filter_map { |service| service['NOMENCLATURE_CODE'].to_s.presence }

    rows.size == actual_codes.size && requested_service_codes.map(&:to_s).uniq.sort == actual_codes.uniq.sort
  end

  private

  attr_reader :command, :provider_patient_code

  def snapshot
    command.request_snapshot
  end

  def destination_reference_matches?(reception, expected_code)
    return reception.is_a?(Hash) && reception['RECEPTION_CODE'].present? if expected_code.blank?

    reference_matches?(reception, expected_code: expected_code)
  end

  def source_identity_matches?(reception)
    reference_matches?(reception) && patient_matches?(reception) && destination_matches?(reception)
  end

  def destination_matches?(reception)
    specialist_matches?(reception) && cabinet_matches?(reception)
  end

  def active?(reception)
    reception.is_a?(Hash) && reception.key?('REMOVED') && reception['REMOVED'].to_i.zero?
  end

  def removed?(reception)
    reception.is_a?(Hash) && reception.key?('REMOVED') && reception['REMOVED'].to_i == 1
  end

  def source_reception_code
    snapshot.fetch('provider_reception_code')
  end

  def specialist_code
    snapshot.dig('reception', 'specialist_code')
  end

  def requested_service_codes
    Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.service_codes(snapshot)
  end

  def reception_time_matches?(reception, start_key:, end_key:)
    provider_time(reception['STARTTIME'])&.to_i == snapshot_time(start_key).to_i &&
      provider_time(reception['ENDTIME'])&.to_i == snapshot_time(end_key).to_i
  end

  def snapshot_time(key)
    Time.iso8601(snapshot.fetch('reception').fetch(key))
  end

  def provider_time(value)
    zone = snapshot.dig('reception', 'time_zone')
    ActiveSupport::TimeZone[zone].parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
