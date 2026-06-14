# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversation do
  describe 'communication thread linkage' do
    let(:account) do
      create(:account).tap { |record| record.enable_features!('communication_threads') }
    end

    it 'links a new conversation to a communication thread after create' do
      conversation = create(:conversation, account: account)

      expect(conversation.reload.communication_thread).to be_present
      expect(conversation.communication_thread.contact).to eq(conversation.contact)
    end

    it 'links conversations from the same contact to the same communication thread' do
      contact = create(:contact, account: account)
      first_conversation = create(:conversation, account: account, contact: contact)
      second_conversation = create(:conversation, account: account, contact: contact)

      expect(second_conversation.reload.communication_thread).to eq(first_conversation.reload.communication_thread)
    end

    it 'refreshes the communication thread when conversation routing fields change', :aggregate_failures do
      assignee = create(:user, account: account)
      team = create(:team, account: account)
      create(:team_member, user: assignee, team: team)
      conversation = create(:conversation, account: account, status: :resolved, priority: :low)
      thread = conversation.reload.communication_thread

      conversation.update!(status: :open, priority: :urgent, assignee: assignee, team: team)

      expect(thread.reload.status).to eq('open')
      expect(thread.priority).to eq('urgent')
      expect(thread.assignee).to eq(assignee)
      expect(thread.team).to eq(team)

      conversation.update!(assignee: nil, team: nil)

      expect(thread.reload.assignee).to be_nil
      expect(thread.team).to be_nil
    end

    it 'refreshes the communication thread when a message changes activity and unread counts', :aggregate_failures do
      conversation = create(:conversation, account: account, agent_last_seen_at: 1.day.ago, last_activity_at: 1.day.ago)
      thread = conversation.reload.communication_thread
      # rubocop:disable Rails/SkipsModelValidations
      thread.update_columns(last_activity_at: 1.day.ago, unread_count: 0, updated_at: Time.current)
      # rubocop:enable Rails/SkipsModelValidations
      message_created_at = 1.minute.ago

      message = create(
        :message,
        account: conversation.account,
        conversation: conversation,
        inbox: conversation.inbox,
        sender: conversation.contact,
        created_at: message_created_at
      )

      expect(thread.reload.last_activity_at).to be_within(1.second).of(message_created_at)
      expect(thread.unread_count).to eq(1)

      message.update!(private: true)

      expect(thread.reload.unread_count).to eq(0)

      message.destroy!

      expect(thread.reload.unread_count).to eq(0)
    end

    it 'skips thread relinking when inbox was already deleted during async cleanup' do
      conversation = create(:conversation, account: account)
      message = create(:message, account: account, conversation: conversation, inbox: conversation.inbox)
      CommunicationThreadConversation.where(conversation_id: conversation.id).delete_all
      Inbox.where(id: conversation.inbox_id).delete_all

      expect { message.destroy! }.not_to raise_error
      expect(CommunicationThreadConversation.where(conversation_id: conversation.id)).to be_none
    end

    it 'creates a missing communication thread before realtime message dispatch', :aggregate_failures do
      conversation = create(:conversation, account: account)
      conversation.reload.communication_thread.destroy!
      conversation.reload
      thread_ids_at_dispatch = []

      allow(Rails.configuration.dispatcher).to receive(:dispatch) do |event_name, *_args, **kwargs|
        next unless event_name == Events::Types::MESSAGE_CREATED

        thread_ids_at_dispatch << kwargs[:message].push_event_data[:communication_thread_id]
      end

      message = create(:message, account: conversation.account, conversation: conversation, inbox: conversation.inbox, sender: conversation.contact)
      thread = conversation.reload.communication_thread

      expect(thread).to be_present
      expect(thread_ids_at_dispatch).to contain_exactly(thread.display_id)
      expect(message.reload.push_event_data[:communication_thread_id]).to eq(thread.display_id)
    end

    it 'includes communication thread and channel metadata in realtime message payloads', :aggregate_failures do
      conversation = create(:conversation, account: account)
      message = create(:message, account: conversation.account, conversation: conversation, inbox: conversation.inbox)

      payload = message.reload.push_event_data

      expect(payload).to include(
        communication_thread_id: conversation.reload.communication_thread.display_id,
        inbox_id: conversation.inbox_id,
        inbox_name: conversation.inbox.name,
        channel: conversation.inbox.channel_type,
        contact_inbox_id: conversation.contact_inbox_id
      )
    end

    it 'does not link or expose communication thread metadata when the feature is disabled', :aggregate_failures do
      disabled_account = create(:account)
      conversation = create(:conversation, account: disabled_account)
      message = create(:message, account: disabled_account, conversation: conversation, inbox: conversation.inbox)

      expect(conversation.reload.communication_thread).to be_nil
      expect(message.reload.push_event_data).not_to include(
        :communication_thread_id,
        :inbox_name,
        :channel,
        :medium,
        :contact_inbox_id
      )
    end
  end
end
