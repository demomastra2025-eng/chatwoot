require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommands::CreateService, '#perform' do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:contact) do
    create(
      :contact,
      account: account,
      custom_attributes: { 'medelement_patient_code' => 'patient-1' }
    )
  end
  let(:resource) do
    create(
      :scheduling_resource,
      account: account,
      custom_attributes: {
        'medelement_specialist_code' => 'specialist-1',
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
      }
    )
  end
  let(:appointment) do
    create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      resource: resource,
      source: 'medelement',
      external_ref: 'medelement:reception:reception-1',
      custom_attributes: { 'medelement_reception_code' => 'reception-1' }
    )
  end
  let(:hook_settings) { attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true) }
  let(:hook) { create(:integrations_hook, :medelement, account: account, settings: hook_settings) }

  before do
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
  end

  it 'extracts the raw provider code from the canonical local external ref' do
    command = described_class.new(
      account: account,
      hook: hook,
      appointment: appointment,
      operation: 'move_reception',
      idempotency_key: 'move-reception-1',
      company_cabinet_code: 'cabinet-1',
      desired_starts_at: appointment.starts_at + 1.day,
      desired_ends_at: appointment.ends_at + 1.day
    ).perform

    expect(command.provider_reception_code).to eq('reception-1')
  end

  it 'rejects a move without a patient reference' do
    contact.update!(custom_attributes: {})

    expect do
      described_class.new(
        account: account,
        hook: hook,
        appointment: appointment,
        operation: 'move_reception',
        idempotency_key: 'move-without-patient',
        company_cabinet_code: 'cabinet-1',
        desired_starts_at: appointment.starts_at + 1.day,
        desired_ends_at: appointment.ends_at + 1.day
      ).perform
    end.to raise_error(ArgumentError, 'contact has no Medelement patient reference')
  end

  it 'uses the Appointment patient reference for a move when the Contact reference is blank' do
    contact.update!(custom_attributes: {})
    appointment.update!(
      custom_attributes: appointment.custom_attributes.merge('medelement_patient_code' => 'patient-appointment')
    )

    command = described_class.new(
      account: account,
      hook: hook,
      appointment: appointment,
      operation: 'move_reception',
      idempotency_key: 'move-with-appointment-patient',
      company_cabinet_code: 'cabinet-1',
      desired_starts_at: appointment.starts_at + 1.day,
      desired_ends_at: appointment.ends_at + 1.day
    ).perform

    expect(command.provider_patient_code).to eq('patient-appointment')
    expect(command.request_snapshot['provider_patient_code']).to eq('patient-appointment')
  end
end
