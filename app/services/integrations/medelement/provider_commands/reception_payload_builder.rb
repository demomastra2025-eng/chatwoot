class Integrations::Medelement::ProviderCommands::ReceptionPayloadBuilder
  def initialize(command:, configuration:)
    @command = command
    @configuration = configuration
  end

  def create_payload(patient_code:)
    payload = {
      patient_code: patient_code,
      specialist_code: specialist_code,
      company_cabinet_code: command.request_snapshot.fetch('company_cabinet_code'),
      starttime: provider_datetime(snapshot_time('destination_starts_at')),
      endtime: provider_datetime(snapshot_time('destination_ends_at')),
      description: reception_snapshot['description'],
      color_code: 0
    }.compact
    service_codes = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.service_codes(command.request_snapshot)
    payload[:nomenclature_code] = service_codes if service_codes.present?
    payload
  end

  def move_payload(patient_code:)
    {
      patient_code: patient_code,
      reception_code: command.request_snapshot.fetch('provider_reception_code'),
      doctor_code: specialist_code,
      start_time: provider_datetime(snapshot_time('destination_starts_at')),
      end_time: provider_datetime(snapshot_time('destination_ends_at'))
    }
  end

  private

  attr_reader :command, :configuration

  def reception_snapshot
    @reception_snapshot ||= command.request_snapshot.fetch('reception')
  end

  def specialist_code
    reception_snapshot.fetch('specialist_code')
  end

  def snapshot_time(key)
    Time.iso8601(reception_snapshot.fetch(key))
  end

  def provider_datetime(value)
    value.in_time_zone(reception_snapshot.fetch('time_zone')).strftime('%d.%m.%Y %H:%M')
  end
end
