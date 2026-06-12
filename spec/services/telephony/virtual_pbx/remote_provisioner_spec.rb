require 'rails_helper'

RSpec.describe Telephony::VirtualPbx::RemoteProvisioner do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:resource_client) { instance_double(Telephony::VirtualPbx::BridgeResourceClient) }
  let(:desired_state) do
    {
      account_id: account.id,
      provider_kind: 'sipuni',
      refs: { number_ref: 'number-ref', trunk_ref: 'trunk-ref', credentials_ref: 'cred-ref' },
      phone_numbers: { fonoster_tel_url: 'tel:056124100014' },
      routing: { mode: 'operator' },
      ownership: { managed_by: 'onelink', onelink_account_id: account.id }
    }
  end
  let(:plan) do
    {
      status: 'dry_run_valid',
      remote_mutations: 'requires_approval',
      operations: [
        {
          key: 'upsert_credentials',
          method: 'PUT',
          path: '/telephony/credentials/cred-ref',
          risk: 'requires_approval',
          payload_preview: { password: '[REDACTED]' }
        },
        { key: 'upsert_trunk', method: 'PUT', path: '/telephony/trunks/trunk-ref', risk: 'requires_approval', payload_preview: {} }
      ]
    }
  end

  def stub_matching_remote_resources
    allow(resource_client).to receive(:number).with('number-ref').and_return(
      'ref' => 'number-ref',
      'telUrl' => 'tel:056124100014',
      'trunkRef' => 'trunk-ref',
      'metadata' => { 'managed_by' => 'onelink', 'onelink_account_id' => account.id },
      'route' => { 'mode' => 'operator' }
    )
    allow(resource_client).to receive(:trunk).with('trunk-ref').and_return('ref' => 'trunk-ref')
    allow(resource_client).to receive(:credential).with('cred-ref').and_return('ref' => 'cred-ref')
  end

  it 'blocks remote execution while the feature flag is disabled and records an audit row' do
    expect(resource_client).not_to receive(:dispatch)

    with_modified_env(TELEPHONY_VIRTUAL_PBX_REMOTE_COMMIT_ENABLED: nil) do
      result = described_class.new(account: account, current_user: admin, resource_client: resource_client)
                              .execute(operation: 'create', desired_state: desired_state, plan: plan, remote_commit: true)

      expect(result).to include(status: 'blocked', remote_commit: false)
      expect(Telephony::ProvisioningRun.last).to have_attributes(status: 'blocked', operation: 'create')
    end
  end

  it 'executes approved non-blocked operations idempotently, verifies read-back, and persists the executed list' do
    allow(resource_client).to receive(:dispatch).and_return({ 'ok' => true })
    stub_matching_remote_resources

    with_modified_env(TELEPHONY_VIRTUAL_PBX_REMOTE_COMMIT_ENABLED: 'true') do
      result = described_class.new(account: account, current_user: admin, resource_client: resource_client)
                              .execute(operation: 'create', desired_state: desired_state, plan: plan, remote_commit: true)

      expect(result).to include(status: 'succeeded', remote_commit: true)
      expect(result.dig(:reconciliation, :status)).to eq('fonoster_synced')
      expect(resource_client).to have_received(:dispatch).twice
      expect(resource_client).to have_received(:number).with('number-ref')
      run = Telephony::ProvisioningRun.last
      expect(run).to have_attributes(status: 'succeeded', operation: 'create', remote_commit: true)
      expect(run.executed_operations.size).to eq(2)
      expect(run.remote_snapshot).to include('number')
    end
  end

  it 'records a failed run when post-commit read-back finds drift' do
    allow(resource_client).to receive(:dispatch).and_return({ 'ok' => true })
    allow(resource_client).to receive(:number).with('number-ref').and_return(
      'ref' => 'number-ref',
      'telUrl' => 'tel:wrong',
      'trunkRef' => 'trunk-ref',
      'metadata' => { 'managed_by' => 'onelink', 'onelink_account_id' => account.id },
      'route' => { 'mode' => 'operator' }
    )
    allow(resource_client).to receive(:trunk).with('trunk-ref').and_return('ref' => 'trunk-ref')
    allow(resource_client).to receive(:credential).with('cred-ref').and_return('ref' => 'cred-ref')

    with_modified_env(TELEPHONY_VIRTUAL_PBX_REMOTE_COMMIT_ENABLED: 'true') do
      result = described_class.new(account: account, current_user: admin, resource_client: resource_client)
                              .execute(operation: 'create', desired_state: desired_state, plan: plan, remote_commit: true)

      expect(result).to include(status: 'requires_manual_reconcile', remote_commit: true)
      expect(result.dig(:errors, 0, :code)).to eq('REMOTE_RECONCILE_FAILED')
      run = Telephony::ProvisioningRun.last
      expect(run).to have_attributes(status: 'failed', error_code: 'REMOTE_RECONCILE_FAILED')
      expect(run.executed_operations.size).to eq(2)
    end
  end
end
