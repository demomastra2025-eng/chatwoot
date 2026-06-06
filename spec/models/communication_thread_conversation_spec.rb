# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreadConversation do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:communication_thread) }
    it { is_expected.to belong_to(:conversation) }
    it { is_expected.to belong_to(:inbox) }
    it { is_expected.to belong_to(:contact_inbox).optional }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:account_id) }
    it { is_expected.to validate_presence_of(:communication_thread_id) }
    it { is_expected.to validate_presence_of(:conversation_id) }
    it { is_expected.to validate_presence_of(:inbox_id) }

    it 'allows one link per account conversation' do
      link = create(:communication_thread_conversation)
      duplicate = build(
        :communication_thread_conversation,
        account: link.account,
        communication_thread: link.communication_thread,
        conversation: link.conversation,
        inbox: link.inbox,
        contact_inbox: link.contact_inbox
      )

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:conversation_id]).to be_present
    end

    it 'rejects cross-contact conversations inside the same account' do
      thread = create(:communication_thread)
      other_conversation = create(:conversation, account: thread.account)
      link = build(
        :communication_thread_conversation,
        account: thread.account,
        communication_thread: thread,
        conversation: other_conversation,
        inbox: other_conversation.inbox,
        contact_inbox: other_conversation.contact_inbox
      )

      expect(link).not_to be_valid
      expect(link.errors[:conversation]).to be_present
    end

    it 'rejects cross-account conversations' do
      thread = create(:communication_thread)
      other_conversation = create(:conversation)
      link = build(
        :communication_thread_conversation,
        account: thread.account,
        communication_thread: thread,
        conversation: other_conversation,
        inbox: other_conversation.inbox,
        contact_inbox: other_conversation.contact_inbox
      )

      expect(link).not_to be_valid
      expect(link.errors[:conversation]).to be_present
    end

    it 'rejects inboxes that do not match the conversation channel' do
      link = build(:communication_thread_conversation)
      other_inbox = create(:inbox, account: link.account)
      link.inbox = other_inbox

      expect(link).not_to be_valid
      expect(link.errors[:inbox]).to be_present
    end

    it 'rejects contact inboxes that do not match the conversation contact inbox' do
      link = build(:communication_thread_conversation)
      other_contact_inbox = create(:contact_inbox, contact: link.conversation.contact, inbox: link.inbox)
      link.contact_inbox = other_contact_inbox

      expect(link).not_to be_valid
      expect(link.errors[:contact_inbox]).to be_present
    end
  end

  describe 'conversation association' do
    it 'exposes the parent communication thread from the child conversation' do
      link = create(:communication_thread_conversation)

      expect(link.conversation.communication_thread).to eq(link.communication_thread)
    end
  end
end
