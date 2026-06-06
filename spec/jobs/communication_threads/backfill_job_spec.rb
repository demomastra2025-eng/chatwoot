# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreads::BackfillJob do
  describe '#perform' do
    it 'reports expected changes without mutating data in dry-run mode' do
      account = create(:account)
      contact = create(:contact, account: account)
      first_conversation = create(:conversation, account: account, contact: contact)
      second_conversation = create(:conversation, account: account, contact: contact)
      CommunicationThreadConversation.delete_all
      CommunicationThread.delete_all

      result = described_class.perform_now(account_id: account.id, dry_run: true)

      expect(result).to include(
        scanned: 2,
        created_threads: 1,
        linked_conversations: 2,
        skipped: 0,
        dry_run: true
      )
      expect(first_conversation.reload.communication_thread).to be_nil
      expect(second_conversation.reload.communication_thread).to be_nil
    end

    it 'creates missing threads and links idempotently' do
      account = create(:account)
      contact = create(:contact, account: account)
      first_conversation = create(:conversation, account: account, contact: contact)
      second_conversation = create(:conversation, account: account, contact: contact)
      CommunicationThreadConversation.delete_all
      CommunicationThread.delete_all

      first_result = described_class.perform_now(account_id: account.id, dry_run: false)
      second_result = described_class.perform_now(account_id: account.id, dry_run: false)

      expect(first_result).to include(scanned: 2, created_threads: 1, linked_conversations: 2, skipped: 0, dry_run: false)
      expect(second_result).to include(scanned: 2, created_threads: 0, linked_conversations: 0, skipped: 0, dry_run: false)
      expect(CommunicationThread.count).to eq(1)
      expect(CommunicationThreadConversation.pluck(:conversation_id)).to contain_exactly(first_conversation.id, second_conversation.id)
    end
  end
end
