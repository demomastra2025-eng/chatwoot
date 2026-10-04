# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe SuperAdmin::ImpersonationService do
  it 'issues a one-time actor-bound grant and rejects replay' do
    actor = create(:super_admin)
    account = create(:account)
    target = create(:user, account: account, role: :administrator)
    grant = described_class.issue_grant!(actor: actor, account: account, target_user: target)
    grant_data = described_class.grant_for(user: target, token: grant.token)

    expect(grant.client_id).to start_with(described_class::CLIENT_PREFIX)
    expect(grant_data).to include(
      'actor_id' => actor.id,
      'account_id' => account.id,
      'target_user_id' => target.id,
      'client_id' => grant.client_id
    )
    expect(described_class.consume_grant!(user: target, token: grant.token, grant: grant_data)).to be(true)
    expect(described_class.consume_grant!(user: target, token: grant.token, grant: grant_data)).to be(false)
    context = described_class.context_for_request(grant.client_id, target_user_id: target.id)
    expect(context).to include(
      'account_id' => account.id,
      'actor_id' => actor.id
    )
    expect(context['pubsub_token']).to match(/\A[0-9a-f]{64}\z/)
    expect(described_class.context_for_websocket(
             grant.client_id, target_user_id: target.id, account_id: account.id, pubsub_token: context['pubsub_token']
           )).to eq(context)
    expect(described_class.context_for_websocket(
             grant.client_id, target_user_id: target.id, account_id: account.id, pubsub_token: target.pubsub_token
           )).to be_nil
  end

  it 'allows only one of two concurrent consumers to claim a support grant' do
    actor = create(:super_admin)
    account = create(:account)
    target = create(:user, account: account, role: :administrator)
    grant = described_class.issue_grant!(actor: actor, account: account, target_user: target)
    grant_data = described_class.grant_for(user: target, token: grant.token)
    ready = Queue.new
    release = Queue.new
    workers = Array.new(2) do
      Thread.new do
        ready << true
        release.pop
        described_class.consume_grant!(user: target, token: grant.token, grant: grant_data)
      end
    end

    2.times { Timeout.timeout(5) { ready.pop } }
    2.times { release << true }
    results = workers.map { |worker| Timeout.timeout(5) { worker.value } }

    expect(results.count(true)).to eq(1)
    expect(results.count(false)).to eq(1)
    expect(described_class.grant_for(user: target, token: grant.token)).to be_nil
  ensure
    2.times { release << true } if release
    workers&.each { |worker| worker.kill if worker.alive? }
    described_class.revoke!(grant.client_id) if grant
  end

  it 'relays only canonical account events addressed to the target through the short-lived token' do
    actor = create(:super_admin)
    account = create(:account)
    other_account = create(:account)
    target = create(:user, account: account)
    other_target = create(:user, account: other_account)
    grant = described_class.issue_grant!(actor: actor, account: account, target_user: target)
    grant_data = described_class.grant_for(user: target, token: grant.token)
    described_class.consume_grant!(user: target, token: grant.token, grant: grant_data)
    context = described_class.context_for_request(grant.client_id, target_user_id: target.id)
    payload = { event: 'message.created', data: { account_id: account.id, message: { id: 7 } } }

    expect(ActionCable.server).to receive(:broadcast).with(context['pubsub_token'], payload).once
    described_class.broadcast_to_active_sessions(
      account_id: account.id, recipient_tokens: [target.pubsub_token, other_target.pubsub_token], payload: payload
    )
    described_class.broadcast_to_active_sessions(
      account_id: other_account.id, recipient_tokens: [target.pubsub_token], payload: payload
    )
    described_class.broadcast_to_active_sessions(
      account_id: account.id,
      recipient_tokens: [target.pubsub_token],
      payload: { event: 'message.created', data: { account_id: other_account.id } }
    )
  end

  it 'revokes the impersonation context if the acting super admin is removed' do
    actor = create(:super_admin)
    account = create(:account)
    target = create(:user, account: account, role: :administrator)
    grant = described_class.issue_grant!(actor: actor, account: account, target_user: target)
    grant_data = described_class.grant_for(user: target, token: grant.token)
    described_class.consume_grant!(user: target, token: grant.token, grant: grant_data)

    actor.destroy!

    expect(described_class.context_for_request(grant.client_id, target_user_id: target.id)).to be_nil
  end

  it 'does not issue a grant for a user outside the selected account' do
    actor = create(:super_admin)
    account = create(:account)
    target = create(:user)

    expect do
      described_class.issue_grant!(actor: actor, account: account, target_user: target)
    end.to raise_error(ArgumentError, /belong to the selected account/)
  end
end
