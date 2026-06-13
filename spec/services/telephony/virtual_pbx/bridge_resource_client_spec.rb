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
