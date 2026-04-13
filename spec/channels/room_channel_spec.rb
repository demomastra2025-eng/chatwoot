require 'rails_helper'

RSpec.describe RoomChannel do
  let!(:contact_inbox) { create(:contact_inbox) }
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account: account) }

  before do
    stub_connection
  end

  it 'subscribes to a stream when pubsub_token is provided' do
    subscribe(pubsub_token: contact_inbox.pubsub_token)
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_for(contact_inbox.pubsub_token)
  end

  it 'subscribes to a stream when pubsub_token is provided for user' do
    user.update!(active_auth_client_id: 'client-1', active_auth_client_set_at: Time.current)

    subscribe(
      user_id: user.id,
      pubsub_token: user.pubsub_token,
      auth_client_id: 'client-1',
      account_id: account.id
    )

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_for(user.pubsub_token)
    expect(subscription).to have_stream_for("account_#{account.id}")
    expect(subscription).to have_stream_for(user.auth_session_stream_name('client-1'))
  end

  it 'rejects user subscriptions for replaced sessions' do
    user.update!(active_auth_client_id: 'client-1', active_auth_client_set_at: Time.current)

    subscribe(
      user_id: user.id,
      pubsub_token: user.pubsub_token,
      auth_client_id: 'stale-client',
      account_id: account.id
    )

    expect(subscription).to be_rejected
  end
end
