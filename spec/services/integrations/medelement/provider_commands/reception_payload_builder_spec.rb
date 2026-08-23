require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommands::ReceptionPayloadBuilder do
  it 'omits nomenclature_code when an appointment has no service' do
    request_snapshot = {
      'version' => 2,
      'company_cabinet_code' => 'cabinet-1',
      'reception' => {
        'time_zone' => 'Asia/Almaty',
        'specialist_code' => 'specialist-1',
        'destination_starts_at' => '2026-08-24T09:00:00+05:00',
        'destination_ends_at' => '2026-08-24T09:30:00+05:00',
        'nomenclature_codes' => []
      }
    }
    command = instance_double(
      Integrations::Medelement::ProviderCommand,
      request_snapshot: request_snapshot
    )

    payload = described_class.new(command: command, configuration: nil).create_payload(patient_code: 'patient-1')

    expect(payload).to include(
      patient_code: 'patient-1',
      specialist_code: 'specialist-1',
      company_cabinet_code: 'cabinet-1'
    )
    expect(payload).not_to have_key(:nomenclature_code)
  end

  it 'keeps selected services local and omits the unverified provider field' do
    request_snapshot = {
      'version' => 2,
      'company_cabinet_code' => 'cabinet-1',
      'reception' => {
        'time_zone' => 'Asia/Almaty',
        'specialist_code' => 'specialist-1',
        'destination_starts_at' => '2026-08-24T09:00:00+05:00',
        'destination_ends_at' => '2026-08-24T09:30:00+05:00',
        'nomenclature_code' => 'service-1',
        'nomenclature_codes' => ['service-1']
      }
    }
    command = instance_double(
      Integrations::Medelement::ProviderCommand,
      request_snapshot: request_snapshot
    )

    payload = described_class.new(command: command, configuration: nil).create_payload(patient_code: 'patient-1')

    expect(payload).not_to have_key(:nomenclature_code)
  end
end
