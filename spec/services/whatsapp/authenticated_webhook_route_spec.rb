require 'rails_helper'

RSpec.describe Whatsapp::AuthenticatedWebhookRoute do
  let(:verification_context) { { hmac_verified: true } }

  before do
    allow(Whatsapp::WabaLock).to receive(:with_locks).and_yield
  end

  it 'registers live priority before routing a messages webhook' do
    route = route_for('messages')
    expect(Whatsapp::WabaLivePriority).to receive(:with_waiters)
      .with(['waba-priority'], waiter_id: 'priority-job')
      .and_yield

    expect(route.with_verified_route { :dispatched }).to be(true)
  end

  it 'does not register live priority for a history-only webhook' do
    route = route_for('history')
    expect(Whatsapp::WabaLivePriority).not_to receive(:with_waiters)

    expect(route.with_verified_route { :dispatched }).to be(true)
  end

  it 'treats a mixed history and messages envelope as live traffic' do
    route = route_for('history', 'messages')
    expect(Whatsapp::WabaLivePriority).to receive(:with_waiters)
      .with(['waba-priority'], waiter_id: 'priority-job')
      .and_yield

    expect(route.with_verified_route { :dispatched }).to be(true)
  end

  it 'fails closed when the ephemeral runtime identity changed between phases' do
    route = route_for('messages')
    allow(route).to receive(:runtime_snapshot).and_return(
      { channel_id: 1, credential_fingerprint: 'rotated' }.with_indifferent_access
    )
    expect(Rails.logger).to receive(:warn)
      .with('[WHATSAPP_WEBHOOK] refused payload because runtime channel identity changed')

    dispatched = false
    result = route.with_verified_route(
      expected_runtime_snapshot: { channel_id: 1, credential_fingerprint: 'original' }
    ) { dispatched = true }

    expect(result).to be(false)
    expect(dispatched).to be(false)
  end

  it 'snapshots routing identity and a one-way credential fingerprint between media phases' do
    inbox = instance_double(Inbox, id: 9)
    channel = instance_double(
      Channel::Whatsapp,
      id: 7,
      account_id: 5,
      inbox: inbox,
      provider: 'whatsapp_cloud',
      phone_number: '+77000000000',
      provider_config: {
        'business_account_id' => 'waba-1',
        'phone_number_id' => 'phone-1',
        'api_key' => 'secret-token'
      }
    )
    route = described_class.new(
      channel: channel,
      payload: payload_with_fields('messages'),
      verification_context: verification_context,
      live_priority_token: 'priority-job'
    )

    expect(route.runtime_snapshot).to include(
      channel_id: 7,
      account_id: 5,
      inbox_id: 9,
      provider: 'whatsapp_cloud',
      waba_id: 'waba-1',
      phone_number_id: 'phone-1',
      route_phone: '+77000000000',
      credential_fingerprint: Digest::SHA256.hexdigest('secret-token')
    )
    expect(route.runtime_snapshot.to_s).not_to include('secret-token')
  end

  it 'returns a frozen verified runtime snapshot without exposing the lock block to callers' do
    route = route_for('messages')
    snapshot = { channel_id: 7, credential_fingerprint: 'fingerprint' }.with_indifferent_access
    allow(route).to receive(:runtime_snapshot).and_return(snapshot)

    result = route.verified_runtime_snapshot

    expect(result).to eq(snapshot)
    expect(result).to be_frozen
  end

  def route_for(*fields)
    route = described_class.new(
      channel: nil,
      payload: payload_with_fields(*fields),
      verification_context: verification_context,
      live_priority_token: 'priority-job'
    )
    allow(route).to receive(:authenticated_route_matches?).and_return(true)
    route
  end

  def payload_with_fields(*fields)
    {
      entry: [
        {
          id: 'waba-priority',
          changes: fields.map { |field| { field: field, value: {} } }
        }
      ]
    }
  end
end
