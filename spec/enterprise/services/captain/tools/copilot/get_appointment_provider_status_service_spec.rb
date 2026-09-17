require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::GetAppointmentProviderStatusService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    account.enable_features!('scheduling')
  end

  it 'returns the current outcome for the exact account-scoped provider command' do
    command = instance_double(Integrations::Medelement::ProviderCommand, id: 55)
    scope = instance_double(ActiveRecord::Relation)
    receipt = {
      appointment_id: 31,
      expected_operation: 'move_reception',
      linked: true,
      terminal: true,
      command: { id: 55, status: 'succeeded', terminal: true }
    }
    allow(Integrations::Medelement::ProviderCommand).to receive(:where).with(account_id: account.id).and_return(scope)
    allow(scope).to receive(:find).with(55).and_return(command)
    allow(Integrations::Medelement::ProviderCommandReceiptBuilder).to receive(:build).with(command: command).and_return(receipt)

    payload = JSON.parse(service.execute(provider_command_id: 55))

    expect(payload.fetch('provider_command_receipt')).to include(
      'appointment_id' => 31,
      'expected_operation' => 'move_reception',
      'linked' => true,
      'terminal' => true,
      'command' => include('id' => 55, 'status' => 'succeeded')
    )
  end

  it 'rejects an invalid provider command id' do
    expect(service.execute(provider_command_id: 0)).to include('ERROR:', 'provider_command_id')
  end
end
