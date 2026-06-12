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

    it 'does not update conversations the agent cannot access' do
      inaccessible_conversation = create(:conversation, account_id: account.id, status: :open)
      params = {
        type: 'Conversation',
        fields: { status: 'snoozed' },
        ids: [conversation_1.display_id, inaccessible_conversation.display_id]
      }

      described_class.perform_now(account: account, params: params, user: agent)

      expect(conversation_1.reload.status).to eq('snoozed')
      expect(inaccessible_conversation.reload.status).to eq('open')
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
    end
  end
end
