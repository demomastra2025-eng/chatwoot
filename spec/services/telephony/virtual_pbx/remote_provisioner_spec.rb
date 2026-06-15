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
  end

  it 'blocks remote execution when remote commit is not requested and records an audit row' do
    expect(resource_client).not_to receive(:dispatch)

    result = described_class.new(account: account, current_user: admin, resource_client: resource_client)
                            .execute(operation: 'create', desired_state: desired_state, plan: plan, remote_commit: false)

    expect(result).to include(status: 'blocked', remote_commit: false)
    expect(Telephony::ProvisioningRun.last).to have_attributes(status: 'blocked', operation: 'create')
  end

  it 'executes approved non-blocked operations idempotently, verifies read-back, and persists the executed list' do
    allow(resource_client).to receive(:dispatch).and_return({ 'ok' => true })
    stub_matching_remote_resources

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

  it 'persists Fonoster generated agent refs and reconciles agents by the remote ref' do
    sip_profile = create(:telephony_sip_profile, account: account, agent_ref: 'local-agent-ref', fonoster_agent_ref: 'local-agent-ref')
    agent_state = desired_state.merge(
      refs: {},
      resources: {},
      profiles: [
        {
          id: sip_profile.id,
          user_id: sip_profile.user_id,
          internal_extension: sip_profile.internal_extension,
          agent_ref: 'local-agent-ref',
          fonoster_agent_ref: 'local-agent-ref',
          enabled: true
        }
      ]
    )
    agent_plan = plan.merge(
      operations: [
        { key: 'upsert_agent', method: 'PUT', path: '/telephony/agents/local-agent-ref', risk: 'requires_approval', payload_preview: {} }
      ]
    )

    allow(resource_client).to receive(:dispatch).and_return({ 'ref' => 'remote-agent-uuid' })
    allow(resource_client).to receive(:agent).with('remote-agent-uuid').and_return(
      'ref' => 'remote-agent-uuid',
      'enabled' => true
    )

    result = described_class.new(account: account, current_user: admin, resource_client: resource_client)
                            .execute(operation: 'update', desired_state: agent_state, plan: agent_plan, remote_commit: true)

    expect(result).to include(status: 'succeeded', remote_commit: true)
    expect(resource_client).to have_received(:agent).with('remote-agent-uuid')
    expect(sip_profile.reload.fonoster_agent_ref).to eq('remote-agent-uuid')
    expect(sip_profile.agent_ref).to eq('local-agent-ref')
  end

  it 'uses a Fonoster generated provider credential ref for subsequent trunk sync and local persistence' do
    provider_connection = create(
      :telephony_provider_connection,
      account: account,
      credentials_ref: 'local-connection-cred',
      fonoster_credentials_ref: nil,
      fonoster_trunk_ref: 'trunk-ref'
    )
    connection_state = desired_state.merge(
      refs: { number_ref: 'number-ref', trunk_ref: 'trunk-ref', credentials_ref: 'local-connection-cred' },
      resources: { provider_connection_id: provider_connection.id },
      connection: {
        name: 'Sipuni trunk',
        username: provider_connection.username,
        password: 'raw-connection-password',
        credentials_ref: 'local-connection-cred'
      }
    )
    connection_plan = plan.merge(
      operations: [
        {
          key: 'upsert_connection_credentials',
          method: 'PUT',
          path: '/telephony/credentials/local-connection-cred',
          risk: 'requires_approval',
          payload: { ref: 'local-connection-cred', password: '[REDACTED]' }
        },
        {
          key: 'upsert_trunk',
          method: 'PUT',
          path: '/telephony/trunks/trunk-ref',
          risk: 'requires_approval',
          payload: { ref: 'trunk-ref', outboundCredentialsRef: 'local-connection-cred' }
        }
      ]
    )

    expect(resource_client).to receive(:dispatch).with(
      hash_including(
        key: 'upsert_connection_credentials',
        payload: hash_including(ref: 'local-connection-cred', password: 'raw-connection-password')
      )
    ).ordered.and_return({ 'ref' => 'remote-connection-cred' })
    expect(resource_client).to receive(:dispatch).with(
      hash_including(
        key: 'upsert_trunk',
        path: '/telephony/trunks/trunk-ref',
        payload: hash_including(outboundCredentialsRef: 'remote-connection-cred')
      )
    ).ordered.and_return({ 'ref' => 'trunk-ref' })
    allow(resource_client).to receive(:number).with('number-ref').and_return(
      'ref' => 'number-ref',
      'telUrl' => 'tel:056124100014',
      'trunkRef' => 'trunk-ref',
      'metadata' => { 'managed_by' => 'onelink', 'onelink_account_id' => account.id },
      'route' => { 'mode' => 'operator' }
    )
    allow(resource_client).to receive(:trunk).with('trunk-ref').and_return('ref' => 'trunk-ref')

    result = described_class.new(account: account, current_user: admin, resource_client: resource_client)
                            .execute(operation: 'create', desired_state: connection_state, plan: connection_plan, remote_commit: true)

    expect(result).to include(status: 'succeeded', remote_commit: true)
    expect(provider_connection.reload).to have_attributes(
      credentials_ref: 'remote-connection-cred',
      fonoster_credentials_ref: 'remote-connection-cred'
    )
  end

  it 'prefers the persisted Fonoster provider credential ref when syncing trunks' do
    trunk_state = desired_state.merge(
      refs: { number_ref: 'number-ref', trunk_ref: 'trunk-ref', credentials_ref: 'local-connection-cred' },
      connection: { credentials_ref: 'local-connection-cred', fonoster_credentials_ref: 'remote-connection-cred' }
    )
    trunk_plan = plan.merge(
      operations: [
        {
          key: 'upsert_trunk',
          method: 'PUT',
          path: '/telephony/trunks/trunk-ref',
          risk: 'requires_approval',
          payload: { ref: 'trunk-ref', outboundCredentialsRef: 'local-connection-cred' }
        }
      ]
    )

    expect(resource_client).to receive(:dispatch).with(
      hash_including(
        key: 'upsert_trunk',
        payload: hash_including(
          credentialsRef: 'remote-connection-cred',
          outboundCredentialsRef: 'remote-connection-cred'
        )
      )
    ).and_return({ 'ref' => 'trunk-ref' })
    allow(resource_client).to receive(:number).with('number-ref').and_return(
      'ref' => 'number-ref',
      'telUrl' => 'tel:056124100014',
      'trunkRef' => 'trunk-ref',
      'metadata' => { 'managed_by' => 'onelink', 'onelink_account_id' => account.id },
      'route' => { 'mode' => 'operator' }
    )
    allow(resource_client).to receive(:trunk).with('trunk-ref').and_return('ref' => 'trunk-ref')

    result = described_class.new(account: account, current_user: admin, resource_client: resource_client)
                            .execute(operation: 'update', desired_state: trunk_state, plan: trunk_plan, remote_commit: true)

    expect(result).to include(status: 'succeeded', remote_commit: true)
  end

  it 'uses a Fonoster generated trunk ref for subsequent number sync and reconciliation' do
    trunk_uuid = 'remote-trunk-uuid'
    trunk_plan = plan.merge(
      operations: [
        {
          key: 'upsert_trunk',
          method: 'PUT',
          path: '/telephony/trunks/trunk-ref',
          risk: 'requires_approval',
          payload: { ref: 'trunk-ref', name: 'Sipuni trunk' }
        },
        {
          key: 'upsert_number',
          method: 'PUT',
          path: '/telephony/numbers/number-ref',
          risk: 'requires_approval',
          payload: { ref: 'number-ref', telUrl: 'tel:056124100014', trunkRef: 'trunk-ref' }
        }
      ]
    )

    expect(resource_client).to receive(:dispatch).with(
      hash_including(key: 'upsert_trunk')
    ).ordered.and_return({ 'ref' => trunk_uuid })
    expect(resource_client).to receive(:dispatch).with(
      hash_including(
        key: 'upsert_number',
        payload: hash_including(trunkRef: trunk_uuid)
      )
    ).ordered.and_return({ 'ref' => 'number-ref' })
    allow(resource_client).to receive(:number).with('number-ref').and_return(
      'ref' => 'number-ref',
      'telUrl' => 'tel:056124100014',
      'trunkRef' => trunk_uuid,
      'metadata' => { 'managed_by' => 'onelink', 'onelink_account_id' => account.id },
      'route' => { 'mode' => 'operator' }
    )
    allow(resource_client).to receive(:trunk).with(trunk_uuid).and_return('ref' => trunk_uuid)

    result = described_class.new(account: account, current_user: admin, resource_client: resource_client)
                            .execute(operation: 'create', desired_state: desired_state, plan: trunk_plan, remote_commit: true)

    expect(result).to include(status: 'succeeded', remote_commit: true)
    expect(resource_client).to have_received(:trunk).with(trunk_uuid)
  end

  it 'injects transient SIP passwords only into credential dispatch payloads' do
    sip_profile = create(
      :telephony_sip_profile,
      account: account,
      agent_ref: 'local-agent-ref',
      fonoster_agent_ref: 'local-agent-ref',
      credentials_ref: 'cred-profile-ref',
      sip_username: '015856100014'
    )
    agent_state = desired_state.merge(
      refs: {},
      resources: {},
      profiles: [
        {
          id: sip_profile.id,
          user_id: sip_profile.user_id,
          internal_extension: sip_profile.internal_extension,
          agent_ref: 'local-agent-ref',
          fonoster_agent_ref: 'local-agent-ref',
          credentials_ref: 'cred-profile-ref',
          sip_username: '015856100014',
          sip_password: 'raw-profile-password',
          enabled: true
        }
      ]
    )
    agent_plan = plan.merge(
      operations: [
        {
          key: 'upsert_agent_credentials',
          method: 'PUT',
          path: '/telephony/credentials/cred-profile-ref',
          risk: 'requires_approval',
          payload: {
            ref: 'cred-profile-ref',
            name: sip_profile.internal_extension,
            username: '015856100014',
            password: '[REDACTED]'
          }
        },
        {
          key: 'upsert_sipuni_gateway',
          method: 'PUT',
          path: '/telephony/sipuni-gateways/gateway-ref',
          risk: 'requires_approval',
          payload: {
            ref: 'gateway-ref',
            numberRef: 'gateway-ref',
            providerAccountNumber: '015856100014',
            credentialsRef: 'cred-profile-ref'
          }
        },
        {
          key: 'upsert_agent',
          method: 'PUT',
          path: '/telephony/agents/local-agent-ref',
          risk: 'requires_approval',
          payload: {
            ref: 'local-agent-ref',
            credentialsRef: 'cred-profile-ref'
          }
        }
      ]
    )

    expect(resource_client).to receive(:dispatch).with(
      hash_including(
        key: 'upsert_agent_credentials',
        payload: hash_including(
          ref: 'cred-profile-ref',
          name: sip_profile.internal_extension,
          username: '015856100014',
          password: 'raw-profile-password'
        )
      )
    ).and_return({ 'ref' => 'remote-credential-uuid' })
    expect(resource_client).to receive(:dispatch).with(
      hash_including(
        key: 'upsert_sipuni_gateway',
        payload: hash_including(
          providerAccountNumber: '015856100014',
          credentialsRef: 'remote-credential-uuid'
        )
      )
    ).and_return({ 'ok' => true })
    expect(resource_client).to receive(:dispatch).with(
      hash_including(
        key: 'upsert_agent',
        payload: hash_including(
          ref: 'local-agent-ref',
          credentialsRef: 'remote-credential-uuid'
        )
      )
    ).and_return({ 'ok' => true })
    allow(resource_client).to receive(:agent).with('local-agent-ref').and_return(
      'ref' => 'local-agent-ref',
      'credentials' => { 'ref' => 'remote-credential-uuid' },
      'enabled' => true
    )

    result = described_class.new(account: account, current_user: admin, resource_client: resource_client)
                            .execute(operation: 'update', desired_state: agent_state, plan: agent_plan, remote_commit: true)

    expect(result).to include(status: 'succeeded', remote_commit: true)
    run = Telephony::ProvisioningRun.last
    expect(run.desired_snapshot.to_json).not_to include('raw-profile-password')
    expect(run.planned_operations.to_json).not_to include('raw-profile-password')
    expect(sip_profile.reload).to have_attributes(
      credentials_ref: 'remote-credential-uuid',
      fonoster_credentials_ref: 'remote-credential-uuid',
      password_secret_ref: 'remote-credential-uuid'
    )
  end

  it 'treats approved delete operations as complete without read-back reconciliation' do
    allow(resource_client).to receive(:dispatch).and_return({ 'ok' => true })
    expect(resource_client).not_to receive(:number)
    expect(resource_client).not_to receive(:trunk)

    delete_plan = plan.merge(
      operations: [
        { key: 'delete_number', method: 'DELETE', path: '/telephony/numbers/number-ref', risk: 'requires_approval' },
        { key: 'delete_trunk', method: 'DELETE', path: '/telephony/trunks/trunk-ref', risk: 'requires_approval' }
      ]
    )

    result = described_class.new(account: account, current_user: admin, resource_client: resource_client)
                            .execute(operation: 'delete', desired_state: desired_state, plan: delete_plan, remote_commit: true)

    expect(result).to include(status: 'succeeded', remote_commit: true)
    expect(result).not_to have_key(:reconciliation)
    expect(resource_client).to have_received(:dispatch).twice
    expect(Telephony::ProvisioningRun.last).to have_attributes(status: 'succeeded', operation: 'delete')
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

    result = described_class.new(account: account, current_user: admin, resource_client: resource_client)
                            .execute(operation: 'create', desired_state: desired_state, plan: plan, remote_commit: true)

    expect(result).to include(status: 'requires_manual_reconcile', remote_commit: true)
    expect(result.dig(:errors, 0, :code)).to eq('REMOTE_RECONCILE_FAILED')
    run = Telephony::ProvisioningRun.last
    expect(run).to have_attributes(status: 'failed', error_code: 'REMOTE_RECONCILE_FAILED')
    expect(run.executed_operations.size).to eq(2)
  end
end
