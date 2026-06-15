require 'rails_helper'

RSpec.describe Telephony::VirtualPbx::BridgeResourceClient do
  let(:bridge) { instance_double(Telephony::BridgeClient) }
  let(:client) { described_class.new(bridge_client: bridge, idempotency_key: 'idem-123') }

  it 'normalizes provider resource upserts and forwards idempotency key' do
    expect(bridge).to receive(:put).with(
      '/telephony/trunks/trunk-ref',
      hash_including(name: 'Sipuni trunk', metadata: hash_including(managed_by: 'onelink')),
      idempotency_key: 'idem-123'
    ).and_return('ref' => 'trunk-ref')

    result = client.upsert_trunk(
      'trunk-ref',
      name: 'Sipuni trunk',
      metadata: { managed_by: 'onelink', password: 'do-not-log' },
      ignored: 'drop-me'
    )

    expect(result).to include('ref' => 'trunk-ref')
  end

  it 'forwards credential passwords while keeping sanitizer redaction separate' do
    expect(bridge).to receive(:put).with(
      '/telephony/credentials/cred-profile-1',
      hash_including(name: 'John 504', username: '015856100014', password: 'raw-secret'),
      idempotency_key: 'idem-123'
    ).and_return('ref' => 'cred-profile-1')

    result = client.upsert_credentials(
      'cred-profile-1',
      name: 'John 504',
      username: '015856100014',
      password: 'raw-secret'
    )

    expect(result).to include('ref' => 'cred-profile-1')
  end

  it 'maps bridge 404s to remote resource not found' do
    allow(bridge).to receive(:get).and_raise(
      Telephony::Error.new(code: 'BRIDGE_REQUEST_FAILED', message: 'HTTP 404 missing', status: :not_found)
    )

    expect { client.number('missing-number') }.to raise_error(Telephony::Error) { |error|
      expect(error.code).to eq('REMOTE_RESOURCE_NOT_FOUND')
      expect(error.message).to include('missing-number')
    }
  end

  it 'falls back to collection create when an upsert update target is missing' do
    expect(bridge).to receive(:put).with(
      '/telephony/trunks/trunk-ref',
      hash_including(ref: 'trunk-ref', name: 'Sipuni trunk'),
      idempotency_key: 'idem-123'
    ).and_raise(
      Telephony::Error.new(
        code: 'BRIDGE_REQUEST_FAILED',
        message: 'HTTP 500 5 NOT_FOUND: The requested resource was not found',
        status: :bad_gateway
      )
    )
    expect(bridge).to receive(:post).with(
      '/telephony/trunks',
      hash_including(ref: 'trunk-ref', name: 'Sipuni trunk'),
      idempotency_key: 'idem-123'
    ).and_return('ref' => 'trunk-ref')

    expect(client.upsert_trunk('trunk-ref', name: 'Sipuni trunk')).to include('ref' => 'trunk-ref')
  end

  it 'adopts and updates an existing Fonoster agent when deterministic agent ref is missing' do
    expect(bridge).to receive(:put).with(
      '/telephony/agents/profile-8-1-504',
      hash_including(
        ref: 'profile-8-1-504',
        username: '504',
        domainUri: 'operator.cloud.vconsult.kz',
        credentialsRef: 'remote-credential-uuid'
      ),
      idempotency_key: 'idem-123'
    ).and_raise(
      Telephony::Error.new(
        code: 'BRIDGE_REQUEST_FAILED',
        message: 'HTTP 500 5 NOT_FOUND: The requested resource was not found',
        status: :bad_gateway
      )
    )
    expect(bridge).to receive(:get).with('/telephony/agents', idempotency_key: 'idem-123').and_return(
      'items' => [
        {
          'ref' => 'remote-agent-uuid',
          'username' => '504',
          'domain' => 'operator.cloud.vconsult.kz',
          'credentials' => { 'ref' => 'old-credential-uuid' }
        }
      ]
    )
    expect(bridge).to receive(:put).with(
      '/telephony/agents/remote-agent-uuid',
      hash_including(
        ref: 'remote-agent-uuid',
        username: '504',
        domainUri: 'operator.cloud.vconsult.kz',
        credentialsRef: 'remote-credential-uuid'
      ),
      idempotency_key: 'idem-123'
    ).and_return('ref' => 'remote-agent-uuid')
    expect(bridge).not_to receive(:post)

    result = client.upsert_agent(
      'profile-8-1-504',
      username: '504',
      domainUri: 'operator.cloud.vconsult.kz',
      credentialsRef: 'remote-credential-uuid'
    )

    expect(result).to include('ref' => 'remote-agent-uuid')
  end

  it 'does not adopt duplicate agents even when username and domain match' do
    expect(bridge).to receive(:put).with(
      '/telephony/agents/profile-8-1-504',
      hash_including(ref: 'profile-8-1-504', username: '504', domainUri: 'operator.cloud.vconsult.kz'),
      idempotency_key: 'idem-123'
    ).and_raise(
      Telephony::Error.new(
        code: 'BRIDGE_REQUEST_FAILED',
        message: 'HTTP 500 5 NOT_FOUND: The requested resource was not found',
        status: :bad_gateway
      )
    )
    expect(bridge).to receive(:get).with('/telephony/agents', idempotency_key: 'idem-123').and_return(
      'items' => [
        { 'ref' => 'agent-a', 'username' => '504', 'domain' => { 'domainUri' => 'operator.cloud.vconsult.kz' } },
        { 'ref' => 'agent-b', 'username' => '504', 'domain' => { 'domainUri' => 'operator.cloud.vconsult.kz' } }
      ]
    )
    expect(bridge).to receive(:post).with(
      '/telephony/agents',
      hash_including(ref: 'profile-8-1-504', username: '504'),
      idempotency_key: 'idem-123'
    ).and_return('ref' => 'new-agent-ref')

    result = client.upsert_agent('profile-8-1-504', username: '504', domainUri: 'operator.cloud.vconsult.kz')

    expect(result).to include('ref' => 'new-agent-ref')
  end

  it 'does not adopt a resource explicitly owned by another OneLink account' do
    expect(bridge).to receive(:put).with(
      '/telephony/agents/profile-8-1-504',
      hash_including(ref: 'profile-8-1-504', username: '504'),
      idempotency_key: 'idem-123'
    ).and_raise(
      Telephony::Error.new(
        code: 'BRIDGE_REQUEST_FAILED',
        message: 'HTTP 500 5 NOT_FOUND: The requested resource was not found',
        status: :bad_gateway
      )
    )
    expect(bridge).to receive(:get).with('/telephony/agents', idempotency_key: 'idem-123').and_return(
      'items' => [
        {
          'ref' => 'other-account-agent',
          'username' => '504',
          'domain' => { 'domainUri' => 'operator.cloud.vconsult.kz' },
          'metadata' => { 'managed_by' => 'onelink', 'onelink_account_id' => 9 }
        }
      ]
    )
    expect(bridge).to receive(:post).with(
      '/telephony/agents',
      hash_including(ref: 'profile-8-1-504', username: '504'),
      idempotency_key: 'idem-123'
    ).and_return('ref' => 'new-agent-ref')

    result = client.upsert_agent(
      'profile-8-1-504',
      username: '504',
      domainUri: 'operator.cloud.vconsult.kz',
      metadata: { managed_by: 'onelink', onelink_account_id: 8 }
    )

    expect(result).to include('ref' => 'new-agent-ref')
  end

  it 'does not adopt an ambiguous agent username without a domain identity' do
    expect(bridge).to receive(:put).with(
      '/telephony/agents/profile-8-1-504',
      hash_including(ref: 'profile-8-1-504', username: '504'),
      idempotency_key: 'idem-123'
    ).and_raise(
      Telephony::Error.new(
        code: 'BRIDGE_REQUEST_FAILED',
        message: 'HTTP 500 5 NOT_FOUND: The requested resource was not found',
        status: :bad_gateway
      )
    )
    expect(bridge).to receive(:get).with('/telephony/agents', idempotency_key: 'idem-123').and_return(
      'items' => [
        { 'ref' => 'agent-domain-a', 'username' => '504', 'domain' => { 'domainUri' => 'domain-a.example.test' } },
        { 'ref' => 'agent-domain-b', 'username' => '504', 'domain' => { 'domainUri' => 'domain-b.example.test' } }
      ]
    )
    expect(bridge).to receive(:post).with(
      '/telephony/agents',
      hash_including(ref: 'profile-8-1-504', username: '504'),
      idempotency_key: 'idem-123'
    ).and_return('ref' => 'new-agent-ref')

    result = client.upsert_agent('profile-8-1-504', username: '504')

    expect(result).to include('ref' => 'new-agent-ref')
  end

  it 'does not adopt ambiguous credentials when neither ref nor name is unique' do
    expect(bridge).to receive(:put).with(
      '/telephony/credentials/cred-profile-8-1-504',
      hash_including(ref: 'cred-profile-8-1-504', name: 'Ahan 504', username: '015856100014'),
      idempotency_key: 'idem-123'
    ).and_raise(
      Telephony::Error.new(
        code: 'BRIDGE_REQUEST_FAILED',
        message: 'HTTP 500 5 NOT_FOUND: The requested resource was not found',
        status: :bad_gateway
      )
    )
    expect(bridge).to receive(:get).with('/telephony/credentials', idempotency_key: 'idem-123').and_return(
      'items' => [
        { 'ref' => 'first-credential-uuid', 'name' => 'John 504', 'username' => '015856100014' },
        { 'ref' => 'second-credential-uuid', 'name' => 'Other 504', 'username' => '015856100014' }
      ]
    )
    expect(bridge).to receive(:post).with(
      '/telephony/credentials',
      hash_including(ref: 'cred-profile-8-1-504', name: 'Ahan 504', username: '015856100014'),
      idempotency_key: 'idem-123'
    ).and_return('ref' => 'new-credential-uuid')

    result = client.dispatch(
      key: 'upsert_agent_credentials',
      method: 'PUT',
      path: '/telephony/credentials/cred-profile-8-1-504',
      payload: { name: 'Ahan 504', username: '015856100014' }
    )

    expect(result).to include('ref' => 'new-credential-uuid')
  end

  it 'does not adopt duplicate credentials with the same SIP username and display name' do
    expect(bridge).to receive(:put).with(
      '/telephony/credentials/cred-profile-8-1-504',
      hash_including(ref: 'cred-profile-8-1-504', name: 'Ahan 504', username: '015856100014'),
      idempotency_key: 'idem-123'
    ).and_raise(
      Telephony::Error.new(
        code: 'BRIDGE_REQUEST_FAILED',
        message: 'HTTP 500 5 NOT_FOUND: The requested resource was not found',
        status: :bad_gateway
      )
    )
    expect(bridge).to receive(:get).with('/telephony/credentials', idempotency_key: 'idem-123').and_return(
      'items' => [
        { 'ref' => 'first-credential-uuid', 'name' => 'Ahan 504', 'username' => '015856100014' },
        { 'ref' => 'second-credential-uuid', 'name' => 'Ahan 504', 'username' => '015856100014' }
      ]
    )
    expect(bridge).to receive(:post).with(
      '/telephony/credentials',
      hash_including(ref: 'cred-profile-8-1-504', name: 'Ahan 504', username: '015856100014'),
      idempotency_key: 'idem-123'
    ).and_return('ref' => 'new-credential-uuid')

    result = client.dispatch(
      key: 'upsert_agent_credentials',
      method: 'PUT',
      path: '/telephony/credentials/cred-profile-8-1-504',
      payload: { name: 'Ahan 504', username: '015856100014' }
    )

    expect(result).to include('ref' => 'new-credential-uuid')
  end

  it 'updates an existing Fonoster credential by SIP username instead of creating duplicates' do
    expect(bridge).to receive(:put).with(
      '/telephony/credentials/cred-profile-8-1-504',
      hash_including(ref: 'cred-profile-8-1-504', name: 'Ahan 504', username: '015856100014', password: 'raw-secret'),
      idempotency_key: 'idem-123'
    ).and_raise(
      Telephony::Error.new(
        code: 'BRIDGE_REQUEST_FAILED',
        message: 'HTTP 500 5 NOT_FOUND: The requested resource was not found',
        status: :bad_gateway
      )
    )
    expect(bridge).to receive(:get).with('/telephony/credentials', idempotency_key: 'idem-123').and_return(
      'items' => [
        { 'ref' => 'matching-credential-uuid', 'name' => 'Ahan 504', 'username' => '015856100014' },
        { 'ref' => 'old-credential-uuid', 'name' => 'John 504', 'username' => '015856100014' }
      ]
    )
    expect(bridge).to receive(:put).with(
      '/telephony/credentials/matching-credential-uuid',
      hash_including(ref: 'matching-credential-uuid', name: 'Ahan 504', username: '015856100014', password: 'raw-secret'),
      idempotency_key: 'idem-123'
    ).and_return('ref' => 'matching-credential-uuid')
    expect(bridge).not_to receive(:post)

    result = client.dispatch(
      key: 'upsert_agent_credentials',
      method: 'PUT',
      path: '/telephony/credentials/cred-profile-8-1-504',
      payload: { name: 'Ahan 504', username: '015856100014', password: 'raw-secret' }
    )

    expect(result).to include('ref' => 'matching-credential-uuid')
  end

  it 'updates an existing Fonoster agent after a concurrent create conflict' do
    expect(bridge).to receive(:put).with(
      '/telephony/agents/profile-8-1-504',
      hash_including(ref: 'profile-8-1-504', username: '504'),
      idempotency_key: 'idem-123'
    ).and_raise(
      Telephony::Error.new(
        code: 'BRIDGE_REQUEST_FAILED',
        message: 'HTTP 500 5 NOT_FOUND: The requested resource was not found',
        status: :bad_gateway
      )
    )
    expect(bridge).to receive(:get).with('/telephony/agents', idempotency_key: 'idem-123').and_return('items' => [])
    expect(bridge).to receive(:post).with(
      '/telephony/agents',
      hash_including(ref: 'profile-8-1-504', username: '504'),
      idempotency_key: 'idem-123'
    ).and_raise(
      Telephony::Error.new(
        code: 'BRIDGE_REQUEST_FAILED',
        message: 'HTTP 500 6 ALREADY_EXISTS: The resource already exists',
        status: :bad_gateway
      )
    )
    expect(bridge).to receive(:get).with('/telephony/agents', idempotency_key: 'idem-123').and_return(
      'items' => [
        { 'ref' => 'remote-agent-uuid', 'username' => '504', 'domain' => { 'domainUri' => 'operator.cloud.vconsult.kz' } }
      ]
    )
    expect(bridge).to receive(:put).with(
      '/telephony/agents/remote-agent-uuid',
      hash_including(ref: 'remote-agent-uuid', username: '504'),
      idempotency_key: 'idem-123'
    ).and_return('ref' => 'remote-agent-uuid')

    result = client.upsert_agent('profile-8-1-504', username: '504', domainUri: 'operator.cloud.vconsult.kz')

    expect(result).to include('ref' => 'remote-agent-uuid')
  end

  it 'adds the path ref when dispatch falls back from update to create' do
    expect(bridge).to receive(:put).with(
      '/telephony/trunks/trunk-ref',
      hash_including(ref: 'trunk-ref', name: 'Sipuni trunk'),
      idempotency_key: 'idem-123'
    ).and_raise(
      Telephony::Error.new(
        code: 'BRIDGE_REQUEST_FAILED',
        message: 'HTTP 500 5 NOT_FOUND: The requested resource was not found',
        status: :bad_gateway
      )
    )
    expect(bridge).to receive(:post).with(
      '/telephony/trunks',
      hash_including(ref: 'trunk-ref', name: 'Sipuni trunk'),
      idempotency_key: 'idem-123'
    ).and_return('ref' => 'trunk-ref')

    result = client.dispatch(
      key: 'upsert_trunk',
      method: 'PUT',
      path: '/telephony/trunks/trunk-ref',
      payload: { name: 'Sipuni trunk' }
    )

    expect(result).to include('ref' => 'trunk-ref')
  end

  it 'treats missing resources as successful deletes' do
    allow(bridge).to receive(:delete).and_raise(
      Telephony::Error.new(
        code: 'BRIDGE_REQUEST_FAILED',
        message: 'HTTP 500 5 NOT_FOUND: The requested resource was not found',
        status: :bad_gateway
      )
    )

    expect(client.delete_number('missing-number')).to include(
      'ok' => true,
      'not_found' => true,
      'path' => '/telephony/numbers/missing-number'
    )
  end

  it 'redacts secret-like fields in payload previews' do
    preview = described_class.sanitize_payload(
      username: 'safe-user',
      password: 'do-not-return',
      nested: { api_token: 'token-value' }
    )

    expect(preview).to include(username: 'safe-user')
    expect(preview[:password]).to eq('[REDACTED]')
    expect(preview.dig(:nested, :api_token)).to eq('[REDACTED]')
  end
end
