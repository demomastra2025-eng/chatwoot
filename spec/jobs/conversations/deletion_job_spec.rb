require 'rails_helper'

RSpec.describe Conversations::DeletionJob do
  let(:account) { create(:account).tap { |record| record.enable_features!('communication_threads') } }
  let(:user) { create(:user, account: account, role: :administrator) }
  let!(:conversation) { create(:conversation, account: account) }

  before { allow(ActionCableBroadcastJob).to receive(:perform_now) }

  def enroll(conversations = [conversation], thread_id: nil)
    Conversations::DeletionService.new(account: account, user: user).create(
      conversations: conversations, request_key: SecureRandom.uuid,
      conversation_ids: conversations.map(&:display_id), thread_id: thread_id
    )
  end

  it 'commits the deletion and terminal receipt together and does not repeat a terminal target' do
    run = enroll
    described_class.perform_now(run.id)
    expect(Conversation.exists?(conversation.id)).to be(false)
    expect(run.reload).to have_attributes(status: 'completed', processed_count: 1, failed_count: 0)
    expect(run.metadata['targets'].first['status']).to eq('deleted')
    receipt = run.metadata.deep_dup
    expect_any_instance_of(DeleteObjectJob).not_to receive(:destroy_tracked_conversation)
    described_class.perform_now(run.id)
    expect(run.reload.metadata).to eq(receipt)
  end

  it 'rolls back the conversation and its dependent links when the receipt cannot be written' do
    account.enable_features!('communication_threads')
    conversation.reload
    thread = conversation.communication_thread
    run = enroll
    allow(Conversations::DeletionService).to receive(:record_target!).and_wrap_original do |method, *args, **kwargs|
      raise ActiveRecord::StatementInvalid, 'receipt write failed' if kwargs[:status] == 'deleted'

      method.call(*args, **kwargs)
    end
    described_class.perform_now(run.id)
    expect(Conversation.exists?(conversation.id)).to be(true)
    expect(thread.communication_thread_conversations.exists?(conversation_id: conversation.id)).to be(true)
    expect(run.reload.metadata['targets'].first).to include('status' => 'failed', 'error_code' => 'destroy_failed')
  end

  it 'preserves genuine deletion if enterprise audit fails after commit' do
    run = enroll
    allow_any_instance_of(DeleteObjectJob).to receive(:finish_tracked_conversation).and_raise('cleanup failed')
    described_class.perform_now(run.id)
    expect(Conversation.exists?(conversation.id)).to be(false)
    expect(run.reload).to have_attributes(status: 'completed', failed_count: 0)
    expect(run.metadata['targets'].first).to include('status' => 'deleted', 'warning_code' => 'audit_failed')
  end

  it 'resumes durable housekeeping after a crash following the primary commit without destroying the target again' do
    thread = conversation.reload.communication_thread
    run = enroll
    interrupted = false
    allow_any_instance_of(described_class).to receive(:cleanup_target).and_wrap_original do |method, *args|
      unless interrupted
        interrupted = true
        raise 'worker stopped after deletion commit'
      end
      method.call(*args)
    end
    clear_enqueued_jobs
    expect { described_class.perform_now(run.id) }.to have_enqueued_job(described_class).with(run.id)
    expect(Conversation.exists?(conversation.id)).to be(false)
    expect(CommunicationThread.exists?(thread.id)).to be(true)
    expect(run.reload.metadata['targets'].first).to include('status' => 'deleted', 'cleanup' => include('status' => 'pending'))
    completed_at = run.completed_at
    expect(Conversations::DeletionService.progress(run)[:metadata]['targets'].first).not_to have_key('cleanup')
    expect_any_instance_of(DeleteObjectJob).not_to receive(:destroy_tracked_conversation)

    described_class.perform_now(run.id)
    expect(CommunicationThread.exists?(thread.id)).to be(false)
    expect(run.reload).to have_attributes(status: 'completed', processed_count: 1, failed_count: 0, completed_at: completed_at)
    expect(run.metadata['targets'].first.dig('cleanup', 'status')).to eq('completed')
  end

  it 'emits the authoritative deletion ID even when housekeeping fails and retries housekeeping alone' do
    run = enroll
    allow_any_instance_of(DeleteObjectJob).to receive(:cleanup_tracked_conversation).and_raise('housekeeping unavailable')
    clear_enqueued_jobs
    expect { described_class.perform_now(run.id) }.to have_enqueued_job(described_class).with(run.id)
    expect(ActionCableBroadcastJob).to have_received(:perform_now).with(
      array_including(user.pubsub_token), Events::Types::CONVERSATION_DELETED,
      { account_id: account.id, id: conversation.display_id }
    )
    expect(run.reload).to have_attributes(status: 'completed', processed_count: 1, failed_count: 0)
    expect(run.metadata['targets'].first).to include('status' => 'deleted', 'warning_code' => 'cleanup_pending')
    expect_any_instance_of(DeleteObjectJob).not_to receive(:destroy_tracked_conversation)
    clear_enqueued_jobs
    perform_enqueued_jobs { described_class.perform_later(run.id) }
    expect(run.reload.metadata['targets'].first).to include('status' => 'deleted', 'warning_code' => 'cleanup_failed')
    expect(run.metadata['targets'].first.dig('cleanup', 'status')).to eq('failed')
    expect(Conversation.exists?(conversation.id)).to be(false)
  end

  it 'broadcasts only safe IDs to current authorized employees of the accepted account' do
    excluded = create(:user, account: account, role: :agent)
    allowed = create(:user, account: account, role: :agent)
    InboxMember.where(user: excluded, inbox: conversation.inbox).delete_all
    outsider = create(:user, account: create(:account), role: :administrator)
    excluded_membership = account.account_users.find_by!(user_id: excluded.id)
    allowed_membership = account.account_users.find_by!(user_id: allowed.id)
    expect(ConversationPolicy.new({ account: account, user: excluded, account_user: excluded_membership }, conversation).show?).to be(false)
    expect(ConversationPolicy.new({ account: account, user: allowed, account_user: allowed_membership }, conversation).show?).to be(true)
    events = []
    allow(ActionCableBroadcastJob).to receive(:perform_now) { |*args| events << args }
    run = enroll
    described_class.perform_now(run.id)
    recipients, event, payload = events.find { |args| args[1] == Events::Types::CONVERSATION_DELETED }
    expect(recipients).to include(user.pubsub_token, allowed.pubsub_token)
    expect(recipients).not_to include(excluded.pubsub_token, outsider.pubsub_token)
    expect(event).to eq(Events::Types::CONVERSATION_DELETED)
    expect(payload).to eq(account_id: account.id, id: conversation.display_id)
  end

  it 'scopes durable housekeeping to the accepted account and preserves a thread with a new conversation ID' do
    thread = conversation.reload.communication_thread
    foreign_thread = create(:communication_thread)
    new_conversation = create(:conversation, account: account, contact: conversation.contact, inbox: conversation.inbox)
    run = enroll
    run.with_lock do
      DeleteObjectJob.new.destroy_tracked_conversation(conversation) do |context|
        context[:communication_thread_ids] << foreign_thread.id
        Conversations::DeletionService.record_target!(run, conversation.id, status: 'deleted', cleanup_context: context)
      end
    end
    expect_any_instance_of(DeleteObjectJob).not_to receive(:destroy_tracked_conversation)
    described_class.perform_now(run.id)
    expect(CommunicationThread.exists?(foreign_thread.id)).to be(true)
    expect(CommunicationThread.exists?(thread.id)).to be(true)
    expect(Conversation.exists?(new_conversation.id)).to be(true)
    expect(run.reload.metadata['targets'].first.dig('cleanup', 'status')).to eq('completed')
  end

  it 'rechecks empty-thread cleanup after taking the native incoming-attachment contact lock' do
    thread = conversation.reload.communication_thread
    run = enroll
    run.with_lock do
      DeleteObjectJob.new.destroy_tracked_conversation(conversation) do |context|
        Conversations::DeletionService.record_target!(run, conversation.id, status: 'deleted', cleanup_context: context)
      end
    end
    lock_id = Digest::SHA256.digest("communication-thread:#{account.id}:#{conversation.contact_id}").unpack1('q>')
    incoming = nil
    attaching = false
    allow(ActiveRecord::Base.connection).to receive(:execute).and_wrap_original do |method, sql, *args|
      if sql == "SELECT pg_advisory_xact_lock(#{lock_id})" && !attaching
        attaching = true
        incoming = create(:conversation, account: account, contact: conversation.contact, inbox: conversation.inbox)
        Conversations::CommunicationThreadResolver.new(conversation: incoming).perform
      end
      method.call(sql, *args)
    end
    expect_any_instance_of(DeleteObjectJob).not_to receive(:destroy_tracked_conversation)
    described_class.perform_now(run.id)
    expect(incoming).to be_present
    expect(CommunicationThread.exists?(thread.id)).to be(true)
    expect(thread.communication_thread_conversations.exists?(conversation_id: incoming.id)).to be(true)
    expect(run.reload.metadata['targets'].first.dig('cleanup', 'status')).to eq('completed')
  end

  it 'keeps an audit warning durable when housekeeping fails and later succeeds' do
    run = enroll
    failed_once = false
    allow_any_instance_of(DeleteObjectJob).to receive(:finish_tracked_conversation).and_raise('audit unavailable')
    allow_any_instance_of(DeleteObjectJob).to receive(:cleanup_tracked_conversation).and_wrap_original do |method, *args|
      unless failed_once
        failed_once = true
        raise 'housekeeping unavailable'
      end
      method.call(*args)
    end
    described_class.perform_now(run.id)
    expect(run.reload.metadata['targets'].first).to include('status' => 'deleted', 'warning_code' => 'cleanup_pending', 'audit_warning_code' => 'audit_failed')
    expect_any_instance_of(DeleteObjectJob).not_to receive(:destroy_tracked_conversation)
    described_class.perform_now(run.id)
    expect(run.reload.metadata['targets'].first).to include('status' => 'deleted', 'warning_code' => 'audit_failed', 'audit_warning_code' => 'audit_failed')
    expect(run.metadata['targets'].first.dig('cleanup', 'status')).to eq('completed')
    expect(Conversations::DeletionService.progress(run)[:metadata]['targets'].first['audit_warning_code']).to eq('audit_failed')
  end

  it 'rechecks permissions and reports partial results for independent exact targets' do
    second = create(:conversation, account: account)
    run = enroll([conversation, second])
    allow_any_instance_of(DeleteObjectJob).to receive(:destroy_tracked_conversation).and_wrap_original do |method, object, &block|
      raise ActiveRecord::RecordNotDestroyed, 'blocked' if object.id == second.id

      method.call(object, &block)
    end
    described_class.perform_now(run.id)
    expect(Conversation.exists?(conversation.id)).to be(false)
    expect(Conversation.exists?(second.id)).to be(true)
    expect(run.reload).to have_attributes(status: 'failed', processed_count: 2, failed_count: 1)
    expect(run.metadata['targets'].map { |target| target['status'] }).to eq(%w[deleted failed])
  end

  it 'leaves a target intact when current destroy permission changed after enrollment' do
    run = enroll
    account.account_users.find_by!(user_id: user.id).update!(role: :agent)
    described_class.perform_now(run.id)
    expect(Conversation.exists?(conversation.id)).to be(true)
    expect(run.reload.metadata['targets'].first).to include('status' => 'failed', 'error_code' => 'permission_changed')
  end

  it 'does not delete a grouped target that is no longer linked to the selected thread' do
    thread = conversation.reload.communication_thread
    run = enroll(thread_id: thread.display_id)
    thread.communication_thread_conversations.where(conversation_id: conversation.id).delete_all
    described_class.perform_now(run.id)
    expect(Conversation.exists?(conversation.id)).to be(true)
    expect(run.reload.metadata['targets'].first['status']).to eq('failed')
  end

  it 'continues a processing receipt without resetting already terminal targets' do
    second = create(:conversation, account: account)
    run = enroll([conversation, second])
    run.with_lock do
      DeleteObjectJob.new.destroy_tracked_conversation(conversation) do
        Conversations::DeletionService.record_target!(run, conversation.id, status: 'deleted')
      end
    end
    expect(run.reload.status).to eq('processing')
    described_class.perform_now(run.id)
    expect(run.reload).to have_attributes(status: 'completed', processed_count: 2)
    expect(Conversation.exists?(second.id)).to be(false)
  end

  it 'retries a transient rollback on the same immutable remaining target without repeating a committed deletion' do
    second = create(:conversation, account: account)
    run = enroll([conversation, second])
    failed_once = false
    deleted_ids = []
    allow_any_instance_of(DeleteObjectJob).to receive(:destroy_tracked_conversation).and_wrap_original do |method, object, &block|
      if object.id == second.id && !failed_once
        failed_once = true
        method.call(object) do
          raise ActiveRecord::Deadlocked, 'transient receipt transaction rollback'
        end
      else
        deleted_ids << object.id
        method.call(object, &block)
      end
    end
    clear_enqueued_jobs
    expect { described_class.perform_now(run.id) }.to have_enqueued_job(described_class).with(run.id)
    expect(Conversation.exists?(conversation.id)).to be(false)
    expect(Conversation.exists?(second.id)).to be(true)
    expect(run.reload.metadata['targets'].map { |target| target['status'] }).to eq(%w[deleted pending])

    described_class.perform_now(run.id)
    expect(run.reload).to have_attributes(status: 'completed', processed_count: 2, failed_count: 0)
    expect(deleted_ids).to eq([conversation.id, second.id])
  end

  it 'marks only remaining pending targets failed after the worker retry budget is exhausted' do
    second = create(:conversation, account: account)
    run = enroll([conversation, second])
    allow_any_instance_of(DeleteObjectJob).to receive(:destroy_tracked_conversation).and_wrap_original do |method, object, &block|
      raise ActiveRecord::SerializationFailure, 'retry' if object.id == second.id

      method.call(object, &block)
    end
    clear_enqueued_jobs
    perform_enqueued_jobs { described_class.perform_later(run.id) }
    expect(run.reload).to have_attributes(status: 'failed', processed_count: 2, failed_count: 1)
    expect(run.metadata['targets'].first['status']).to eq('deleted')
    expect(run.metadata['targets'].last).to include('status' => 'failed', 'error_code' => 'worker_failed')
    expect(Conversation.exists?(second.id)).to be(true)
  end

  it 'does not delete a newly created conversation for the same contact' do
    run = enroll
    new_conversation = create(:conversation, account: account, contact: conversation.contact)
    described_class.perform_now(run.id)
    expect(Conversation.exists?(new_conversation.id)).to be(true)
    expect(run.reload.metadata['targets'].map { |target| target['record_id'] }).to eq([conversation.id])
  end

  it 'ignores another kind of bulk operation' do
    run = account.bulk_action_runs.create!(user: user, resource_type: 'Contact', action_name: 'delete', total_count: 1)
    described_class.perform_now(run.id)
    expect(run.reload.status).to eq('queued')
    expect(Conversation.exists?(conversation.id)).to be(true)
  end
end
