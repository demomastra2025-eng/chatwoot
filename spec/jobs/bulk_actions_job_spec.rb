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

  it 'enqueues the job' do
    expect { job }.to have_enqueued_job(described_class)
      .with(account: account, params: params, user: agent)
      .on_queue('medium')
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

    it 'updates account-readable conversations without inbox membership' do
      account_readable_conversation = create(:conversation, account_id: account.id, status: :open)
      params = {
        type: 'Conversation',
        fields: { status: 'snoozed' },
        ids: [conversation_1.display_id, account_readable_conversation.display_id]
      }

      described_class.perform_now(account: account, params: params, user: agent)

      expect(conversation_1.reload.status).to eq('snoozed')
      expect(account_readable_conversation.reload.status).to eq('snoozed')
    end

    it 'does not bulk update Voice conversations without inbox membership' do
      voice_inbox = create(:channel_voice, :sipuni, account: account).inbox
      voice_conversation = create(:conversation, account: account, inbox: voice_inbox, status: :open)

      described_class.perform_now(
        account: account,
        params: {
          type: 'Conversation',
          fields: { status: 'snoozed' },
          ids: [voice_conversation.display_id]
        },
        user: agent
      )

      expect(voice_conversation.reload).to be_open

      create(:inbox_member, user: agent, inbox: voice_inbox)
      described_class.perform_now(
        account: account,
        params: {
          type: 'Conversation',
          fields: { status: 'snoozed' },
          ids: [voice_conversation.display_id]
        },
        user: agent
      )

      expect(voice_conversation.reload).to be_snoozed
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

    it 'finishes as failed with the exact failed count when some records fail' do
      original_process_record = described_class.instance_method(:process_record)
      allow_any_instance_of(described_class).to receive(:process_record) do |instance, record|
        raise ActiveRecord::RecordInvalid if record.id == conversation_1.id

        original_process_record.bind_call(instance, record)
      end

      described_class.perform_now(
        account: account,
        params: {
          type: 'Conversation',
          fields: { status: 'snoozed' },
          ids: [conversation_1, conversation_2].map(&:display_id)
        },
        user: agent,
        bulk_action_run_id: bulk_action_run.id
      )

      expect(bulk_action_run.reload).to be_failed
      expect(bulk_action_run.processed_count).to eq(2)
      expect(bulk_action_run.failed_count).to eq(1)
      expect(bulk_action_run.error_message).to eq('1 records failed')
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
      let(:voice_inbox) { create(:channel_voice, :sipuni, account: account).inbox }
      let(:voice_conversation) do
        conversation = create(:conversation, account: account, contact: contact, inbox: voice_inbox, status: :open)
        CommunicationThreadConversation.where(account_id: account.id, conversation_id: conversation.id).delete_all
        conversation.association(:communication_thread_conversation).reset
        conversation.association(:communication_thread).reset
        create(:communication_thread_conversation, communication_thread: thread, conversation: conversation)
        conversation
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

      it 'preloads accessible links and link counts once per thread batch' do
        other_conversations = create_list(:conversation, 2, account: account)
        other_conversations.each { |conversation| create(:inbox_member, inbox: conversation.inbox, user: agent) }
        threads = [thread, *other_conversations.map { |conversation| conversation.reload.communication_thread }]
        job_instance = described_class.new
        job_instance.instance_variable_set(:@account, account)
        job_instance.instance_variable_set(:@user, agent)
        link_queries = []
        subscriber = lambda do |_name, _start, _finish, _id, payload|
          next unless payload[:sql].to_s.include?('communication_thread_conversations')

          link_queries << payload[:sql].to_s
        end

        ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
          job_instance.send(:preload_communication_thread_batch, threads)
          threads.each { |communication_thread| job_instance.send(:accessible_links_for, communication_thread) }
        end

        expect(link_queries.size).to eq(2)
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

      it 'resolves an all-matching thread scope on the server and honors exclusions' do
        other_conversation = create(:conversation, account: account, status: :open)
        create(:inbox_member, inbox: other_conversation.inbox, user: agent)
        other_thread = other_conversation.reload.communication_thread

        described_class.perform_now(
          account: account,
          params: {
            type: 'CommunicationThread',
            fields: { status: 'resolved' },
            selection: {
              mode: 'all_matching',
              filters: { status: 'all', assignee_type: 'all' },
              excluded_ids: [thread.display_id]
            }
          },
          user: agent
        )

        expect(thread_conversation_1.reload.status).to eq('open')
        expect(other_conversation.reload.status).to eq('resolved')
        expect(other_thread.reload.status).to eq('resolved')
      end

      it 'does not select a mixed thread through an inaccessible Voice-only advanced filter' do
        voice_conversation

        described_class.perform_now(
          account: account,
          params: {
            type: 'CommunicationThread',
            labels: { add: ['voice-match'] },
            selection: {
              mode: 'all_matching',
              filters: { status: 'all', assignee_type: 'all' },
              payload: [
                { attribute_key: 'inbox_id', filter_operator: 'equal_to', values: [voice_inbox.id] }
              ],
              excluded_ids: []
            }
          },
          user: agent
        )

        expect(thread_conversation_1.reload.label_list).not_to include('voice-match')
        expect(voice_conversation.reload.label_list).not_to include('voice-match')
      end

      it 'does not apply labels before rejecting a combined full-thread update' do
        voice_conversation

        described_class.perform_now(
          account: account,
          params: {
            type: 'CommunicationThread',
            labels: { add: ['partial'] },
            fields: { status: 'resolved' },
            ids: [thread.display_id]
          },
          user: agent
        )

        expect(thread_conversation_1.reload.label_list).not_to include('partial')
        expect(thread_conversation_2.reload.label_list).not_to include('partial')
        expect(voice_conversation.reload.label_list).not_to include('partial')
        expect(thread_conversation_1).to be_open
        expect(thread_conversation_2).to be_open
        expect(voice_conversation).to be_open
      end
    end
  end
end
