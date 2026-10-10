require 'rails_helper'

RSpec.describe Conversations::DeletionService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:conversation) { create(:conversation, account: account) }
  let(:key) { SecureRandom.uuid }
  let(:service) { described_class.new(account: account, user: user) }

  def enroll(request_key: key, ids: [conversation.display_id], conversations: [conversation], thread_id: nil)
    service.create(conversations: conversations, request_key: request_key, conversation_ids: ids, thread_id: thread_id)
  end

  it 'enrolls an immutable account/actor-scoped receipt without claiming deletion' do
    expect { enroll }.to have_enqueued_job(Conversations::DeletionJob).with(kind_of(Integer), nil)
    run = account.bulk_action_runs.last
    expect(run).to have_attributes(user_id: user.id, resource_type: 'Conversation', action_name: 'delete', status: 'queued')
    expect(run.metadata['targets'].first).to include('record_id' => conversation.id, 'conversation_id' => conversation.display_id, 'status' => 'pending')
    expect(described_class.response(run)).to include(accepted_conversation_ids: [conversation.display_id])
    expect(described_class.response(run)).not_to have_key(:deleted_conversation_ids)
    expect(described_class.response(run)[:payload][:metadata]['targets'].first).not_to have_key('routing')
    expect(Conversation.exists?(conversation.id)).to be(true)
  end

  it 'recovers the same UUID before an already absent target needs to be loaded' do
    run = enroll
    Conversations::DeletionJob.perform_now(run.id)
    expect(Conversation.exists?(conversation.id)).to be(false)
    clear_enqueued_jobs
    expect(service.recover(request_key: key, conversation_ids: [conversation.display_id]).id).to eq(run.id)
    expect(enqueued_jobs).to be_empty
  end

  it 'rejects a reused key for another exact selection or operation type' do
    enroll
    expect { service.recover(request_key: key, conversation_ids: [conversation.display_id + 1]) }
      .to raise_error(described_class::KeyConflict)
    expect { service.recover(request_key: key, conversation_ids: [conversation.display_id], thread_id: 1) }
      .to raise_error(described_class::KeyConflict)
  end

  it 'rejects another group/actor request overlapping only a later still pending target' do
    unrelated = create(:conversation, account: account)
    enroll
    other_user = create(:user, account: account, role: :administrator)
    expect do
      described_class.new(account: account, user: other_user).create(
        conversations: [unrelated, conversation], request_key: SecureRandom.uuid,
        conversation_ids: [unrelated.display_id, conversation.display_id], thread_id: 1
      )
    end.to raise_error(described_class::OverlappingRequest)
    expect(account.bulk_action_runs.count).to eq(1)
  end

  it 'allows a terminal target while the same processing run still blocks its pending target' do
    second = create(:conversation, account: account)
    run = enroll(ids: [conversation.display_id, second.display_id], conversations: [conversation, second])
    described_class.record_target!(run, conversation.id, status: 'failed', error_code: 'destroy_failed')

    accepted = enroll(request_key: SecureRandom.uuid)

    expect(run.reload.status).to eq('processing')
    expect(accepted.status).to eq('queued')
    expect do
      enroll(request_key: SecureRandom.uuid, ids: [second.display_id], conversations: [second])
    end.to raise_error(described_class::OverlappingRequest)
  end

  it 'records queue failure as terminal and does not let a late worker delete' do
    allow(Conversations::DeletionJob).to receive(:perform_later).and_raise(ActiveJob::EnqueueError, 'queue unavailable')
    run = enroll
    expect(run.reload).to have_attributes(status: 'failed', failed_count: 1, processed_count: 1)
    expect(run.metadata['targets'].first).to include('status' => 'failed', 'error_code' => 'enqueue_failed')
    Conversations::DeletionJob.perform_now(run.id)
    expect(Conversation.exists?(conversation.id)).to be(true)
  end

  it 'does not expose another actor/account receipt through readonly key lookup' do
    run = enroll
    other_user = create(:user, account: account, role: :administrator)
    expect { described_class.new(account: account, user: other_user).lookup(key) }.to raise_error(ActiveRecord::RecordNotFound)
    other_account = create(:account)
    expect { described_class.new(account: other_account, user: user).lookup(key) }.to raise_error(ActiveRecord::RecordNotFound)
    expect(service.lookup(key).id).to eq(run.id)
  end

  it 'rejects coercible identities, missing UUIDs, foreign records, and oversized requests' do
    [1.2, '1e2', '-1', '0', nil, true, [1], { id: 1 }, (2**53)].each do |value|
      expect { described_class.identity(value) }.to raise_error(described_class::InvalidRequest)
    end
    expect { enroll(request_key: '') }.to raise_error(described_class::InvalidRequest)
    expect { enroll(ids: [conversation.display_id, conversation.display_id.to_s]) }.to raise_error(described_class::InvalidRequest)
    expect { enroll(ids: Array.new(101, 1)) }.to raise_error(described_class::InvalidRequest)
    foreign = create(:conversation)
    expect { enroll(ids: [foreign.display_id], conversations: [foreign]) }.to raise_error(described_class::InvalidRequest)
  end

  it 'requires current account membership and destroy permission' do
    account.account_users.find_by!(user_id: user.id).update!(role: :agent)
    expect { enroll }.to raise_error(Pundit::NotAuthorizedError)
    expect(account.bulk_action_runs).to be_empty
  end
end
