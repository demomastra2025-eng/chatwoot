# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RoomChannel do
  let!(:contact_inbox) { create(:contact_inbox) }
  let!(:account) { create(:account) }
  let!(:other_account) { create(:account) }
  let!(:user) { create(:user, account: account) }

  before do
    stub_connection
  end

  it 'subscribes a contact when a contact inbox pubsub token is provided' do
    subscribe(pubsub_token: contact_inbox.pubsub_token)
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_for(contact_inbox.pubsub_token)
  end

  it 'preserves ordinary user streams for an active customer session' do
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

  it 'accepts impersonation only on an account stream and temporary session token' do
    user.update!(active_auth_client_id: 'customer-client', active_auth_client_set_at: Time.current)
    grant, context = issue_support_session(account: account, target: user)

    subscribe(
      user_id: user.id,
      pubsub_token: context.fetch('pubsub_token'),
      auth_client_id: grant.client_id,
      account_id: account.id
    )

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_for(context.fetch('pubsub_token'))
    expect(subscription).to have_stream_for("account_#{account.id}")
    expect(subscription).not_to have_stream_for(user.pubsub_token)
    expect(subscription).not_to have_stream_for(user.auth_session_stream_name(grant.client_id))
    expect(user.reload).to be_active_auth_client('customer-client')
  end

  it 'rejects the permanent customer pubsub token for an impersonation client' do
    grant, = issue_support_session(account: account, target: user)

    subscribe(
      user_id: user.id,
      pubsub_token: user.pubsub_token,
      auth_client_id: grant.client_id,
      account_id: account.id
    )

    expect(subscription).to be_rejected
  end

  it 'rejects an impersonation websocket request for another account' do
    grant, context = issue_support_session(account: account, target: user)

    subscribe(
      user_id: user.id,
      pubsub_token: context.fetch('pubsub_token'),
      auth_client_id: grant.client_id,
      account_id: other_account.id
    )

    expect(subscription).to be_rejected
  end

  it 'stops existing streams when the support session expires' do
    grant, context = issue_support_session(account: account, target: user)
    subscribe(
      user_id: user.id,
      pubsub_token: context.fetch('pubsub_token'),
      auth_client_id: grant.client_id,
      account_id: account.id
    )
    expect(subscription).to be_confirmed

    travel 16.minutes do
      expect(subscription).to receive(:stop_all_streams).and_call_original
      expect(subscription).not_to receive(:transmit)
      subscription.send(:transmit_support_payload, { event: 'message.created', data: { account_id: account.id } })
    end
  end

  it 'stops existing streams when the acting super admin is revoked' do
    actor = create(:super_admin)
    grant, context = issue_support_session(actor: actor, account: account, target: user)
    subscribe(
      user_id: user.id,
      pubsub_token: context.fetch('pubsub_token'),
      auth_client_id: grant.client_id,
      account_id: account.id
    )
    expect(subscription).to be_confirmed
    actor.destroy!

    expect(subscription).to receive(:stop_all_streams).and_call_original
    expect(subscription).not_to receive(:transmit)
    subscription.send(:transmit_support_payload, { event: 'message.created', data: { account_id: account.id } })
  end

  it 'rejects ordinary user subscriptions for replaced sessions' do
    user.update!(active_auth_client_id: 'client-1', active_auth_client_set_at: Time.current)

    subscribe(
      user_id: user.id,
      pubsub_token: user.pubsub_token,
      auth_client_id: 'stale-client',
      account_id: account.id
    )

    expect(subscription).to be_rejected
  end

  def issue_support_session(actor: create(:super_admin), account:, target:)
    grant = SuperAdmin::ImpersonationService.issue_grant!(actor: actor, account: account, target_user: target)
    grant_data = SuperAdmin::ImpersonationService.grant_for(user: target, token: grant.token)
    expect(SuperAdmin::ImpersonationService.consume_grant!(user: target, token: grant.token, grant: grant_data)).to be(true)
    context = SuperAdmin::ImpersonationService.context_for_request(grant.client_id, target_user_id: target.id)
    [grant, context]
  end
end
