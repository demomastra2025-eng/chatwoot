require 'rails_helper'

RSpec.describe BulkActionsJob do
  params = {
    type: 'Conversation',
    fields: { status: 'snoozed' },
    ids: Conversation.first(3).pluck(:display_id)
  }

  subject(:job) { described_class.perform_later(account: account, params: params, user: agent) }

  let(:account) { create(:account) }
  let!(:agent) { create(:user, account: account, role: :agent) }
  let!(:conversation_1) { create(:conversation, account_id: account.id, status: :open) }
  let!(:conversation_2) { create(:conversation, account_id: account.id, status: :open) }
  let!(:conversation_3) { create(:conversation, account_id: account.id, status: :open) }
  let!(:bulk_action_run) do
    BulkActionRun.create!(
      account: account,
      user: agent,
      resource_type: 'Conversation',
      action_name: 'update_status'
    )
  end

  before do
    Conversation.all.find_each do |conversation|
      create(:inbox_member, inbox: conversation.inbox, user: agent)
    end
  end

  def create_accessible_thread(account:, user:)
    contact = create(:contact, account: account)
    thread = create(:communication_thread, account: account, contact: contact)
    conversation = create(:conversation, account: account, contact: contact)
    CommunicationThreadConversation.where(account_id: account.id, conversation_id: conversation.id).delete_all
    conversation.association(:communication_thread_conversation).reset
    conversation.association(:communication_thread).reset
    account.enable_features!('communication_threads')
    create(:communication_thread_conversation, communication_thread: thread, conversation: conversation)
    create(:inbox_member, inbox: conversation.inbox, user: user) unless InboxMember.exists?(inbox_id: conversation.inbox_id, user_id: user.id)
    [thread, conversation]
  end

  def after_run_start(run)
    runs = account.bulk_action_runs
    allow(account).to receive(:bulk_action_runs).and_return(runs)
    allow(runs).to receive(:find_by).with(id: run.id).and_return(run)
    allow(run).to receive(:start!).and_wrap_original do |original, **kwargs|
      result = original.call(**kwargs)
      yield
      result
    end
  end

  it 'enqueues the job' do
    expect { job }.to have_enqueued_job(described_class)
      .with(account: account, params: params, user: agent)
      .on_queue('medium')
  end

  it 'flushes progress in bounded batches for 10,000 selected records' do
    bulk_job = described_class.new
    bulk_job.instance_variable_set(:@record_ids, (1..10_000).to_a)
    record = Struct.new(:id)
    scope = double
    allow(scope).to receive(:where) { |conditions| conditions.fetch(:id).map { |id| record.new(id) } }
    bulk_job.records = scope
    allow(bulk_job).to receive(:process_record)
    allow(bulk_job).to receive(:flush_progress)

    bulk_job.bulk_update

    expect(bulk_job).to have_received(:flush_progress).with(100, 0, 0).exactly(100).times
  end

  context 'when job is triggered' do
    let(:bulk_action_job) { double }

    before do
      allow(bulk_action_job).to receive(:perform)
    end

    it 'bulk updates the status' do
      params = {
        type: 'Conversation',
        fields: { status: 'snoozed', assignee_id: agent.id },
        ids: Conversation.first(3).pluck(:display_id)
      }

      expect(Conversation.first.status).to eq('open')

      described_class.perform_now(account: account, params: params, user: agent)

      expect(conversation_1.reload.status).to eq('snoozed')
      expect(conversation_2.reload.status).to eq('snoozed')
      expect(conversation_3.reload.status).to eq('snoozed')
    end

    it 'does not update conversations the agent cannot access' do
      inaccessible_conversation = create(:conversation, account_id: account.id, status: :open)
      params = {
        type: 'Conversation',
        fields: { status: 'snoozed' },
        ids: [conversation_1.display_id, inaccessible_conversation.display_id]
      }

      described_class.perform_now(account: account, params: params, user: agent, bulk_action_run_id: bulk_action_run.id)

      expect(conversation_1.reload.status).to eq('snoozed')
      expect(inaccessible_conversation.reload.status).to eq('open')
      expect(bulk_action_run.reload.as_progress_json).to include(total_count: 2, done_count: 1, skipped_count: 1)
    end

    it 'bulk updates the assignee_id' do
      params = {
        type: 'Conversation',
        fields: { status: 'snoozed', assignee_id: agent.id },
        ids: Conversation.first(3).pluck(:display_id)
      }

      expect(Conversation.first.assignee_id).to be_nil

      described_class.perform_now(account: account, params: params, user: agent)

      expect(Conversation.first.assignee_id).to eq(agent.id)
      expect(Conversation.second.assignee_id).to eq(agent.id)
      expect(Conversation.third.assignee_id).to eq(agent.id)
    end

    it 'bulk updates the snoozed_until' do
      params = {
        type: 'Conversation',
        fields: { status: 'snoozed', snoozed_until: Time.zone.now },
        ids: Conversation.first(3).pluck(:display_id)
      }

      expect(Conversation.first.snoozed_until).to be_nil

      described_class.perform_now(account: account, params: params, user: agent)

      expect(Conversation.first.snoozed_until).to be_present
      expect(Conversation.second.snoozed_until).to be_present
      expect(Conversation.third.snoozed_until).to be_present
    end

    it 'tracks progress and completion for the bulk action run' do
      params = {
        type: 'Conversation',
        fields: { status: 'snoozed' },
        ids: Conversation.first(3).pluck(:display_id)
      }

      described_class.perform_now(
        account: account,
        params: params,
        user: agent,
        bulk_action_run_id: bulk_action_run.id
      )

      expect(bulk_action_run.reload).to be_completed
      expect(bulk_action_run.total_count).to eq(3)
      expect(bulk_action_run.processed_count).to eq(3)
      expect(bulk_action_run.failed_count).to eq(0)
    end

    it 'resets skipped accounting when the same run is retried' do
      run = account.bulk_action_runs.create!(
        user: agent,
        resource_type: 'Conversation',
        action_name: 'update_status'
      )
      InboxMember.where(inbox_id: conversation_1.inbox_id, user_id: agent.id).delete_all
      params = {
        type: 'Conversation',
        fields: { status: 'resolved' },
        ids: [conversation_1.display_id],
        record_ids: [conversation_1.id]
      }
      bulk_job = described_class.new
      attempts = 0
      allow(bulk_job).to receive(:bulk_update).and_wrap_original do |original|
        attempts += 1
        result = original.call
        raise 'one-time completion failure' if attempts == 1

        result
      end

      expect do
        bulk_job.perform(
          account: account,
          params: params,
          user: agent,
          bulk_action_run_id: run.id,
          selection_count: 1
        )
      end.to raise_error('one-time completion failure')
      expect(run.reload.as_progress_json[:skipped_count]).to eq(1)

      bulk_job.perform(
        account: account,
        params: params,
        user: agent,
        bulk_action_run_id: run.id,
        selection_count: 1
      )

      expect(run.reload).to be_completed
      expect(run.total_count).to eq(1)
      expect(run.processed_count).to eq(1)
      expect(run.as_progress_json[:skipped_count]).to eq(1)
    end

    it 'does not repeat a completed mark-read run on duplicate delivery' do
      run = account.bulk_action_runs.create!(
        user: agent,
        resource_type: 'Conversation',
        action_name: 'mark_read'
      )
      params = { type: 'Conversation', action_name: 'mark_read', ids: [conversation_1.display_id] }

      described_class.perform_now(account: account, params: params, user: agent, bulk_action_run_id: run.id)
      expect(run.reload).to be_completed

      expect(Conversations::MarkReadService).not_to receive(:new)
      described_class.perform_now(account: account, params: params, user: agent, bulk_action_run_id: run.id)
      expect(run.reload.processed_count).to eq(1)
    end

    it 'rechecks access revoked after run start and reports the frozen selection as skipped' do
      run = account.bulk_action_runs.create!(
        user: agent,
        resource_type: 'Conversation',
        action_name: 'update_status'
      )
      after_run_start(run) do
        InboxMember.where(inbox_id: conversation_1.inbox_id, user_id: agent.id).delete_all
      end

      described_class.perform_now(
        account: account,
        user: agent,
        params: {
          type: 'Conversation',
          fields: { status: 'resolved' },
          ids: [conversation_1.display_id],
          record_ids: [conversation_1.id]
        },
        bulk_action_run_id: run.id,
        selection_count: 1
      )

      expect(conversation_1.reload.status).to eq('open')
      expect(run.reload).to be_completed
      expect(run.total_count).to eq(1)
      expect(run.processed_count).to eq(1)
      expect(run.failed_count).to eq(0)
      expect(run.as_progress_json[:skipped_count]).to eq(1)
    end

    it 'rechecks account membership and reports the complete snapshot as skipped' do
      run = account.bulk_action_runs.create!(
        user: agent,
        resource_type: 'Conversation',
        action_name: 'update_status'
      )
      after_run_start(run) do
        account.account_users.where(user_id: agent.id).delete_all
      end

      described_class.perform_now(
        account: account,
        params: {
          type: 'Conversation',
          fields: { status: 'resolved' },
          ids: [conversation_1.display_id],
          record_ids: [conversation_1.id]
        },
        user: agent,
        bulk_action_run_id: run.id,
        selection_count: 1
      )

      expect(conversation_1.reload.status).to eq('open')
      expect(run.reload).to be_completed
      expect(run.total_count).to eq(1)
      expect(run.processed_count).to eq(1)
      expect(run.failed_count).to eq(0)
      expect(run.as_progress_json[:skipped_count]).to eq(1)
    end

    it 'enforces required attributes on the server and accepts a present false checkbox value' do
      account.enable_features!('conversation_required_attributes')
      account.update!(
        settings: account.settings.merge(
          'conversation_required_attributes' => ['needs_review']
        )
      )
      create(
        :custom_attribute_definition,
        account: account,
        attribute_key: 'needs_review',
        attribute_model: :conversation_attribute,
        attribute_display_type: :checkbox
      )
      conversation_1.update!(custom_attributes: {})
      conversation_2.update!(custom_attributes: { 'needs_review' => false })
      run = account.bulk_action_runs.create!(
        user: agent,
        resource_type: 'Conversation',
        action_name: 'update_status'
      )

      described_class.perform_now(
        account: account,
        params: {
          type: 'Conversation',
          fields: { status: 'resolved' },
          ids: [conversation_1.display_id, conversation_2.display_id],
          record_ids: [conversation_1.id, conversation_2.id]
        },
        user: agent,
        bulk_action_run_id: run.id,
        selection_count: 2
      )

      expect(conversation_1.reload.status).to eq('open')
      expect(conversation_2.reload.status).to eq('resolved')
      expect(run.reload).to be_completed
      expect(run.total_count).to eq(2)
      expect(run.processed_count).to eq(2)
      expect(run.failed_count).to eq(0)
      expect(run.as_progress_json[:skipped_count]).to eq(1)
    end

    it 'preserves the status reason when closing a conversation in the job' do
      account.update!(
        conversation_status_reason_config: {
          'resolved' => { options: ['Resolved by request'], required: true }
        }
      )

      described_class.perform_now(
        account: account,
        params: {
          type: 'Conversation',
          fields: { status: 'resolved', status_reason: 'Resolved by request' },
          ids: [conversation_1.display_id]
        },
        user: agent
      )

      expect(conversation_1.reload.status).to eq('resolved')
      expect(conversation_1.status_transitions.last.reason).to eq('Resolved by request')
    end

    context 'with communication threads' do
      let(:contact) { create(:contact, account: account) }
      let(:thread) { create(:communication_thread, account: account, contact: contact) }
      let(:thread_conversation_1) { create(:conversation, account: account, contact: contact, status: :open) }
      let(:second_inbox) { create(:inbox, account: account) }
      let(:second_contact_inbox) { create(:contact_inbox, contact: contact, inbox: second_inbox) }
      let(:thread_conversation_2) do
        create(
          :conversation,
          account: account,
          contact: contact,
          inbox: second_inbox,
          contact_inbox: second_contact_inbox,
          status: :open
        )
      end

      before do
        thread
        thread_conversation_1
        thread_conversation_2
        CommunicationThreadConversation.where(
          account_id: account.id,
          conversation_id: [thread_conversation_1.id, thread_conversation_2.id]
        ).delete_all
        [thread_conversation_1, thread_conversation_2].each do |conversation|
          conversation.association(:communication_thread_conversation).reset
          conversation.association(:communication_thread).reset
        end
        account.enable_features!('communication_threads')
        create(:communication_thread_conversation, communication_thread: thread, conversation: thread_conversation_1, primary: true)
        create(:communication_thread_conversation, communication_thread: thread, conversation: thread_conversation_2)
        create(:inbox_member, inbox: thread_conversation_1.inbox, user: agent)
        create(:inbox_member, inbox: thread_conversation_2.inbox, user: agent)
      end

      it 'does not update a replacement thread that reused a selected display ID' do
        snapshot = BulkActions::SelectionSnapshot.new(
          account: account,
          user: agent,
          resource_type: 'CommunicationThread',
          filters: { mode: 'basic', status: 'all', inbox_id: thread_conversation_1.inbox_id }
        ).perform
        selected_record_id = thread.id
        selected_display_id = thread.display_id
        thread.destroy!

        replacement_contact = create(:contact, account: account)
        replacement = create(:communication_thread, account: account, contact: replacement_contact)
        replacement_conversation = create(
          :conversation,
          account: account,
          contact: replacement_contact,
          inbox: Inbox.find(thread_conversation_1.inbox_id)
        )
        CommunicationThreadConversation.where(account_id: account.id, conversation_id: replacement_conversation.id).delete_all
        replacement_conversation.association(:communication_thread_conversation).reset
        replacement_conversation.association(:communication_thread).reset
        create(:communication_thread_conversation, communication_thread: replacement, conversation: replacement_conversation)
        expect(replacement.display_id).to eq(selected_display_id)
        expect(replacement.id).not_to eq(selected_record_id)
        run = account.bulk_action_runs.create!(
          user: agent,
          resource_type: 'CommunicationThread',
          action_name: 'update_status'
        )

        described_class.perform_now(
          account: account,
          user: agent,
          params: {
            type: 'CommunicationThread',
            fields: { status: 'resolved' },
            ids: snapshot.ids,
            record_ids: snapshot.record_ids
          },
          bulk_action_run_id: run.id,
          selection_count: snapshot.count
        )

        expect([replacement.reload.status, replacement_conversation.reload.status]).to eq(%w[open open])
        expect(run.reload).to be_completed
        expect(run.total_count).to eq(1)
        expect(run.processed_count).to eq(1)
        expect(run.as_progress_json[:skipped_count]).to eq(1)
      end

      it 'bulk updates the thread status through linked conversations' do
        described_class.perform_now(
          account: account,
          params: { type: 'CommunicationThread', fields: { status: 'resolved' }, ids: [thread.display_id] },
          user: agent
        )

        expect(thread_conversation_1.reload.status).to eq('resolved')
        expect(thread_conversation_2.reload.status).to eq('resolved')
        expect(thread.reload.status).to eq('resolved')
      end

      it 'bulk adds labels to linked conversations' do
        described_class.perform_now(
          account: account,
          params: { type: 'CommunicationThread', labels: { add: %w[vip support] }, ids: [thread.display_id] },
          user: agent
        )

        expect(thread_conversation_1.reload.label_list).to contain_exactly('vip', 'support')
        expect(thread_conversation_2.reload.label_list).to contain_exactly('vip', 'support')
      end

      it 'bulk marks linked conversations as read and refreshes the thread unread count' do
        create(:message, account: account, conversation: thread_conversation_1, inbox: thread_conversation_1.inbox)
        create(:message, account: account, conversation: thread_conversation_2, inbox: thread_conversation_2.inbox)
        thread_conversation_1.reload.refresh_communication_thread!

        expect(thread.reload.unread_count).to eq(2)

        described_class.perform_now(
          account: account,
          params: { type: 'CommunicationThread', action_name: 'mark_read', ids: [thread.display_id] },
          user: agent
        )

        expect(thread_conversation_1.reload.unread_incoming_messages_count).to eq(0)
        expect(thread_conversation_2.reload.unread_incoming_messages_count).to eq(0)
        expect(thread.reload.unread_count).to eq(0)
      end

      it 'fails a whole-thread update when one linked inbox is no longer accessible' do
        run = account.bulk_action_runs.create!(
          user: agent,
          resource_type: 'CommunicationThread',
          action_name: 'update_status'
        )
        InboxMember.where(inbox_id: thread_conversation_2.inbox_id, user_id: agent.id).delete_all

        described_class.perform_now(
          account: account,
          params: {
            type: 'CommunicationThread',
            fields: { status: 'resolved' },
            ids: [thread.display_id],
            record_ids: [thread.id]
          },
          user: agent,
          bulk_action_run_id: run.id,
          selection_count: 1
        )

        expect(thread_conversation_1.reload.status).to eq('open')
        expect(thread_conversation_2.reload.status).to eq('open')
        expect(run.reload).to be_completed
        expect(run.total_count).to eq(1)
        expect(run.processed_count).to eq(1)
        expect(run.failed_count).to eq(1)
        expect(run.as_progress_json[:skipped_count]).to eq(0)
      end
    end
  end
end
