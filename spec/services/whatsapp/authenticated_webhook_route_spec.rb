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
