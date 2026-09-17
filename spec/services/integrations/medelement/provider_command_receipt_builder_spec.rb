require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommandReceiptBuilder do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:contact) { create(:contact, account: account, phone_number: '+77001230001') }
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
  let(:appointment) { create(:scheduling_appointment, account: account, contact: contact, resource: resource) }
  let(:hook_settings) { attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true) }
  let(:hook) { create(:integrations_hook, :medelement, account: account, settings: hook_settings) }

  before do
    account.enable_features!('scheduling')
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
  end

  it 'links an intent to its concrete provider command and exposes a pollable terminal contract' do
    command = Integrations::Medelement::ProviderCommands::CreateService.new(
      account: account,
      hook: hook,
      appointment: appointment,
      operation: 'create_reception',
      idempotency_key: 'create-reception-receipt-1',
      company_cabinet_code: 'cabinet-1',
      actor: user
    ).perform

    receipt = described_class.build(command: command)

    expect(receipt).to include(
      appointment_id: appointment.id,
      expected_operation: 'create_reception',
      lookup_tool: 'get_appointment_provider_status',
      linked: true,
      terminal: false
    )
    expect(receipt.fetch(:command)).to include(
      id: command.id,
      operation: 'create_reception',
      status: 'awaiting_confirmation',
      idempotency_key: 'create-reception-receipt-1',
      terminal: false
    )
  end

  it 'does not fabricate a receipt when no provider command exists' do
    expect(described_class.build(command: nil)).to be_nil
  end
end
