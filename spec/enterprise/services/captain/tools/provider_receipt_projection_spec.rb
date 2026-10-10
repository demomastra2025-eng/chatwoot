require 'rails_helper'

RSpec.describe Captain::Tools::ProviderReceiptProjection do
  let(:receipt) do
    { appointment_id: 17, expected_operation: 'move_reception', lookup_tool: described_class::REMOVED_AGENT_TOOL,
      command: { id: 23, status: 'succeeded', provider_reception_code: 'receipt-17' } }
  end

  it 'keeps operation evidence without advertising the removed customer tool' do
    payload = { success: true, appointments: [{ provider_command_receipt: receipt }] }

    projected = described_class.for_agent(payload)

    expect(projected[:appointments].first[:provider_command_receipt]).to eq(receipt.except(:lookup_tool))
    expect(receipt[:lookup_tool]).to eq('get_appointment_provider_status')
    expect(projected[:success]).to be true
  end

  it 'preserves JSON transport and all receipt identifiers' do
    result = JSON.parse(described_class.for_agent(JSON.generate(provider_command_receipt: receipt)))

    expect(result['provider_command_receipt']).to eq(receipt.except(:lookup_tool).deep_stringify_keys)
  end

  it 'does not erase unrelated tool hints or ordinary text' do
    expect(described_class.for_agent({ 'lookup_tool' => 'get_appointment' })).to eq('lookup_tool' => 'get_appointment')
    expect(described_class.for_agent('Appointment created')).to eq('Appointment created')
  end
end
