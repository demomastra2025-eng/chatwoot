require 'rails_helper'

RSpec.describe Telephony::VirtualPbx::Reconciler do
  let(:account) { create(:account) }
  let(:resource_client) { instance_double(Telephony::VirtualPbx::BridgeResourceClient) }
  let(:desired_state) do
    {
      account_id: account.id,
      inbox_id: 10,
      refs: { number_ref: 'number-ref', trunk_ref: 'trunk-ref', credentials_ref: 'cred-ref' },
      phone_numbers: { fonoster_tel_url: 'tel:056124100014' },
      routing: { mode: 'operator' },
      ownership: { managed_by: 'onelink', onelink_account_id: account.id, onelink_inbox_id: 10 }
    }
  end

  it 'returns fonoster_synced when live remote resources match OneLink desired state' do
    allow(resource_client).to receive(:number).with('number-ref').and_return(
      'ref' => 'number-ref',
      'telUrl' => 'tel:056124100014',
      'trunk' => { 'ref' => 'trunk-ref', 'name' => 'Provider trunk' },
      'metadata' => { 'managed_by' => 'onelink', 'onelink_account_id' => account.id, 'onelink_inbox_id' => 10 },
      'route' => { 'mode' => 'operator' }
    )
    allow(resource_client).to receive(:trunk).with('trunk-ref').and_return('ref' => 'trunk-ref')

    result = described_class.new(account: account, resource_client: resource_client).check(desired_state)

    expect(result).to include(status: 'fonoster_synced', ready: true)
    expect(result.fetch(:drift)).to eq([])
  end

  it 'does not report agent AOR drift when the bridge read-back omits AOR fields' do
    state = desired_state.merge(
      profiles: [{ agent_ref: 'agent-ref', agent_aor: 'sip:100@operator.example.test', enabled: true }]
    )
    allow(resource_client).to receive(:number).with('number-ref').and_return(
      'ref' => 'number-ref',
      'telUrl' => 'tel:056124100014',
      'trunk' => { 'ref' => 'trunk-ref' },
      'metadata' => { 'managed_by' => 'onelink', 'onelink_account_id' => account.id },
      'route' => { 'mode' => 'operator' }
    )
    allow(resource_client).to receive(:trunk).with('trunk-ref').and_return('ref' => 'trunk-ref')
    allow(resource_client).to receive(:agent).with('agent-ref').and_return(
      'ref' => 'agent-ref',
      'username' => '100',
      'enabled' => true
    )

    result = described_class.new(account: account, resource_client: resource_client).check(state)

    expect(result).to include(status: 'fonoster_synced', ready: true)
    expect(result.fetch(:drift)).to eq([])
  end

  it 'reports credentials drift when the remote agent omits credentials read-back' do
    state = desired_state.merge(
      profiles: [{ agent_ref: 'agent-ref', credentials_ref: 'expected-credential-ref', enabled: true }]
    )
    allow(resource_client).to receive(:number).with('number-ref').and_return(
      'ref' => 'number-ref',
      'telUrl' => 'tel:056124100014',
      'trunk' => { 'ref' => 'trunk-ref' },
      'metadata' => { 'managed_by' => 'onelink', 'onelink_account_id' => account.id },
      'route' => { 'mode' => 'operator' }
    )
    allow(resource_client).to receive(:trunk).with('trunk-ref').and_return('ref' => 'trunk-ref')
    allow(resource_client).to receive(:agent).with('agent-ref').and_return(
      'ref' => 'agent-ref',
      'username' => '100',
      'enabled' => true
    )

    result = described_class.new(account: account, resource_client: resource_client).check(state)

    expect(result).to include(status: 'requires_manual_reconcile', ready: false)
    expect(result.fetch(:drift).map { |item| item[:code] }).to include('remote_agent_credentials_mismatch')
  end

  it 'fails closed with requires_manual_reconcile when bridge resources are missing' do
    allow(resource_client).to receive(:number).and_raise(
      Telephony::Error.new(code: 'REMOTE_RESOURCE_NOT_FOUND', message: 'missing number', status: :not_found)
    )
    allow(resource_client).to receive(:trunk).with('trunk-ref').and_return('ref' => 'trunk-ref')

    result = described_class.new(account: account, resource_client: resource_client).check(desired_state)

    expect(result).to include(status: 'requires_manual_reconcile', ready: false)
    expect(result.fetch(:drift).map { |item| item[:code] }).to include('remote_number_missing')
    expect(result.to_json).not_to include('password')
  end

  it 'detects runtime app and employee agent drift' do
    state = desired_state.deep_merge(
      refs: { runtime_app_ref: 'app-ref' },
      routing: { mode: 'operator', app_ref: 'app-ref' },
      profiles: [{ agent_ref: 'agent-ref', agent_aor: 'sip:100@operator.example.test', credentials_ref: 'expected-credential-ref', enabled: true }]
    )
    allow(resource_client).to receive(:number).with('number-ref').and_return(
      'ref' => 'number-ref',
      'telUrl' => 'tel:056124100014',
      'trunkRef' => 'trunk-ref',
      'metadata' => { 'managed_by' => 'onelink', 'onelink_account_id' => account.id },
      'route' => { 'mode' => 'operator', 'appRef' => 'wrong-app' }
    )
    allow(resource_client).to receive(:trunk).with('trunk-ref').and_return('ref' => 'trunk-ref')
    allow(resource_client).to receive(:agent).with('agent-ref').and_return(
      'ref' => 'agent-ref',
      'agentAor' => 'sip:101@operator.example.test',
      'credentials' => { 'ref' => 'wrong-credential-ref' },
      'enabled' => false
    )

    result = described_class.new(account: account, resource_client: resource_client).check(state)

    expect(result).to include(status: 'requires_manual_reconcile', ready: false)
    expect(result.fetch(:drift).map { |item| item[:code] }).to include(
      'remote_runtime_app_mismatch',
      'remote_agent_aor_mismatch',
      'remote_agent_credentials_mismatch',
      'remote_agent_enabled_mismatch'
    )
  end
end
