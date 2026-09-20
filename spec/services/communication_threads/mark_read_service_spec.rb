# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreads::MarkReadService do
  let(:account) do
    create(:account).tap { |record| record.enable_features!('communication_threads') }
  end
  let(:user) { create(:user, account: account) }
  let(:conversation) { create(:conversation, account: account, agent_last_seen_at: 1.day.ago) }
  let(:thread) { conversation.reload.communication_thread }
  let(:links) { thread.communication_thread_conversations }

  describe '#perform' do
    it 'marks unread conversations and queues one aggregate realtime refresh' do
      message = create(:message, account: account, conversation: conversation, message_type: :incoming, created_at: 1.minute.ago)
      allow(CommunicationThreads::RealtimeUpdateJob).to receive(:perform_later)

      service = described_class.new(
        communication_thread: thread,
        current_user: user,
        current_account: account,
        accessible_links: links
      )
      updated_thread = service.perform

      expect(conversation.reload.agent_last_seen_at).to be > message.created_at
      expect(updated_thread.unread_count).to eq(0)
      expect(service.last_seen_at).to be_within(0.001.seconds).of(conversation.agent_last_seen_at)
      expect(service.read_state_changed).to be(true)
      expect(service.sidebar_counts_refresh_required).to be(true)
      expect(service.channel_read_states).to contain_exactly(
        a_hash_including(conversation_id: conversation.display_id, unread_count: 0)
      )
      expect(CommunicationThreads::RealtimeUpdateJob).to have_received(:perform_later).once.with(
        communication_thread_id: thread.id,
        source_conversation_id: conversation.id,
        source_event: 'conversation.read',
        performer_id: user.id
      )
    end

    it 'is a no-op when every accessible conversation is already read' do
      create(:message, account: account, conversation: conversation, message_type: :incoming, created_at: 2.days.ago)
      allow(Notification::MarkConversationReadService).to receive(:new)
      allow(Conversations::MarkReadService).to receive(:new)
      allow(CommunicationThreads::RealtimeUpdateJob).to receive(:perform_later)

      service = described_class.new(
        communication_thread: thread,
        current_user: user,
        current_account: account,
        accessible_links: links
      )
      service.perform

      expect(service.read_state_changed).to be(false)
      expect(service.sidebar_counts_refresh_required).to be(false)
      expect(Notification::MarkConversationReadService).not_to have_received(:new)
      expect(Conversations::MarkReadService).not_to have_received(:new)
      expect(CommunicationThreads::RealtimeUpdateJob).not_to have_received(:perform_later)
    end

    it 'repairs a stale aggregate unread count even when messages are already read' do
      create(:message, account: account, conversation: conversation, message_type: :incoming, created_at: 2.days.ago)
      thread.update!(unread_count: 1)
      allow(CommunicationThreads::RealtimeUpdateJob).to receive(:perform_later)

      service = described_class.new(
        communication_thread: thread,
        current_user: user,
        current_account: account,
        accessible_links: links
      )
      updated_thread = service.perform

      expect(updated_thread.unread_count).to eq(0)
      expect(service.read_state_changed).to be(false)
      expect(service.sidebar_counts_refresh_required).to be(true)
      expect(CommunicationThreads::RealtimeUpdateJob).to have_received(:perform_later).once
    end

    it 'does not request sidebar counts when the aggregate remains unread for another reader' do
      create(:message, account: account, conversation: conversation, message_type: :incoming, created_at: 1.minute.ago)
      Conversations::RecordUserReadStateService.new(conversation: conversation, user: user).perform(last_seen_at: Time.current)
      allow(CommunicationThreads::RealtimeUpdateJob).to receive(:perform_later)

      service = described_class.new(
        communication_thread: thread.reload,
        current_user: user,
        current_account: account,
        accessible_links: links
      )
      updated_thread = service.perform

      expect(updated_thread.unread_count).to eq(1)
      expect(service.read_state_changed).to be(false)
      expect(service.sidebar_counts_refresh_required).to be(false)
      expect(CommunicationThreads::RealtimeUpdateJob).to have_received(:perform_later).once
    end

    it 'still clears an unread conversation notification when message state is already read' do
      create(:message, account: account, conversation: conversation, message_type: :incoming, created_at: 2.days.ago)
      create(:notification, account: account, user: user, primary_actor: conversation, read_at: nil)
      notification_service = instance_double(Notification::MarkConversationReadService, perform: true)
      conversation_service = instance_double(Conversations::MarkReadService, perform: true)
      allow(Notification::MarkConversationReadService).to receive(:new).and_return(notification_service)
      allow(Conversations::MarkReadService).to receive(:new).and_return(conversation_service)
      allow(CommunicationThreads::RealtimeUpdateJob).to receive(:perform_later)

      service = described_class.new(
        communication_thread: thread,
        current_user: user,
        current_account: account,
        accessible_links: links
      )
      service.perform

      expect(service.read_state_changed).to be(true)
      expect(service.sidebar_counts_refresh_required).to be(false)
      expect(notification_service).to have_received(:perform)
      expect(conversation_service).to have_received(:perform)
      expect(CommunicationThreads::RealtimeUpdateJob).to have_received(:perform_later).once
    end
  end
end
