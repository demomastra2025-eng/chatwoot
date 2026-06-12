# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversations::CommunicationThreadResolver do
  describe '#perform' do
    let(:account) do
      create(:account).tap { |record| record.enable_features!('communication_threads') }
    end

    it 'creates a communication thread and links the conversation', :aggregate_failures do
      conversation = create(:conversation, account: account, status: :open, priority: :high)

      thread = described_class.new(conversation: conversation).perform

      expect(thread).to be_persisted
      expect(thread.account).to eq(conversation.account)
      expect(thread.contact).to eq(conversation.contact)
      expect(thread.status).to eq(conversation.status)
      expect(thread.priority).to eq(conversation.priority)
      expect(thread.communication_thread_conversations.count).to eq(1)

      link = thread.communication_thread_conversations.first
      expect(link.conversation).to eq(conversation)
      expect(link.inbox).to eq(conversation.inbox)
      expect(link.contact_inbox).to eq(conversation.contact_inbox)
      expect(link).to be_primary
      expect(conversation.reload.communication_thread).to eq(thread)
    end

    it 'reuses the existing contact thread across different inbox conversations' do
      contact = create(:contact, account: account)
      first_conversation = create(:conversation, account: account, contact: contact)
      second_inbox = create(:inbox, account: account)
      second_contact_inbox = create(:contact_inbox, contact: contact, inbox: second_inbox)
      second_conversation = create(
        :conversation,
        account: account,
        contact: contact,
        inbox: second_inbox,
        contact_inbox: second_contact_inbox
      )

      first_thread = described_class.new(conversation: first_conversation).perform
      second_thread = described_class.new(conversation: second_conversation).perform

      expect(second_thread).to eq(first_thread)
      expect(first_thread.conversations).to contain_exactly(first_conversation, second_conversation)
      expect(first_thread.communication_thread_conversations.where(primary: true).count).to eq(1)
    end

    it 'is idempotent for the same conversation' do
      conversation = create(:conversation, account: account)

      first_thread = described_class.new(conversation: conversation).perform
      second_thread = described_class.new(conversation: conversation).perform

      expect(second_thread).to eq(first_thread)
      expect(CommunicationThread.count).to eq(1)
      expect(CommunicationThreadConversation.count).to eq(1)
    end

    it 'moves a conversation to the thread for the current contact', :aggregate_failures do
      old_contact = create(:contact, account: account)
      old_inbox = create(:inbox, account: account)
      old_contact_inbox = create(:contact_inbox, contact: old_contact, inbox: old_inbox)
      moved_conversation = create(
        :conversation,
        account: account,
        contact: old_contact,
        inbox: old_inbox,
        contact_inbox: old_contact_inbox
      )
      remaining_conversation = create(:conversation, account: account, contact: old_contact)
      old_thread = described_class.new(conversation: moved_conversation).perform
      described_class.new(conversation: remaining_conversation).perform
      new_contact = create(:contact, account: account)
      new_contact_inbox = create(:contact_inbox, contact: new_contact, inbox: old_inbox)

      # rubocop:disable Rails/SkipsModelValidations
      moved_conversation.update_columns(
        contact_id: new_contact.id,
        contact_inbox_id: new_contact_inbox.id,
        updated_at: Time.current
      )
      # rubocop:enable Rails/SkipsModelValidations

      new_thread = described_class.new(conversation: moved_conversation.reload).perform

      expect(new_thread).not_to eq(old_thread)
      expect(new_thread.contact).to eq(new_contact)
      expect(new_thread.conversations).to contain_exactly(moved_conversation)
      expect(old_thread.reload.conversations).to contain_exactly(remaining_conversation)
      primary_links = old_thread.communication_thread_conversations.where(primary: true)
      expect(primary_links.count).to eq(1)
      expect(moved_conversation.reload.communication_thread).to eq(new_thread)
    end

    it 'refreshes aggregate fields from linked conversations', :aggregate_failures do
      contact = create(:contact, :with_email, account: account)
      first_conversation = create(:conversation, account: account, contact: contact)
      second_conversation = create(:conversation, account: account, contact: contact)
      latest_activity_at = 2.minutes.ago

      create(
        :message,
        account: account,
        conversation: first_conversation,
        inbox: first_conversation.inbox,
        sender: contact,
        created_at: 1.day.ago
      )
      create(
        :message,
        account: account,
        conversation: second_conversation,
        inbox: second_conversation.inbox,
        sender: contact,
        created_at: latest_activity_at
      )

      # rubocop:disable Rails/SkipsModelValidations
      first_conversation.update_columns(
        status: Conversation.statuses[:resolved],
        priority: Conversation.priorities[:low],
        last_activity_at: 1.day.ago,
        agent_last_seen_at: 2.days.ago,
        updated_at: Time.current
      )
      second_conversation.update_columns(
        status: Conversation.statuses[:pending],
        priority: Conversation.priorities[:urgent],
        last_activity_at: latest_activity_at,
        agent_last_seen_at: 2.days.ago,
        updated_at: Time.current
      )
      # rubocop:enable Rails/SkipsModelValidations

      thread = described_class.new(conversation: second_conversation.reload).perform

      expect(thread.status).to eq('pending')
      expect(thread.priority).to eq('urgent')
      expect(thread.last_activity_at).to be_within(1.second).of(latest_activity_at)
      expect(thread.unread_count).to eq(2)
    end

    it 'uses the latest active linked conversation status instead of always preferring open' do
      contact = create(:contact, account: account)
      open_conversation = create(:conversation, account: account, contact: contact, status: :open)
      pending_conversation = create(:conversation, account: account, contact: contact, status: :pending)

      open_conversation.update_column(:updated_at, 10.minutes.ago)
      pending_conversation.update_column(:updated_at, Time.current)

      thread = described_class.new(conversation: pending_conversation.reload).perform

      expect(thread.status).to eq('pending')
    end
  end
end
