# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreads::UnreadCountRepairService do
  let(:account) do
    create(:account).tap { |record| record.enable_features!('communication_threads') }
  end
  let(:imported_conversation) { create(:conversation, account: account, agent_last_seen_at: nil) }
  let(:live_conversation) { create(:conversation, account: account, agent_last_seen_at: 1.day.ago) }
  let!(:imported_message) do
    create(
      :message,
      account: account,
      inbox: imported_conversation.inbox,
      conversation: imported_conversation,
      message_type: :incoming,
      content_attributes: { imported_history: true },
      created_at: 2.days.ago
    )
  end
  let!(:live_message) do
    create(
      :message,
      account: account,
      inbox: live_conversation.inbox,
      conversation: live_conversation,
      message_type: :incoming,
      created_at: 1.hour.ago
    )
  end

  before do
    imported_conversation.reload.communication_thread.update!(unread_count: 1)
    live_conversation.reload.communication_thread.update!(unread_count: 5)
  end

  it 'reports drift without changing data in dry-run mode' do
    result = described_class.new(account: account, dry_run: true).perform

    expect(result).to include(
      account_id: account.id,
      scanned_threads: 2,
      drifted_threads: 2,
      updated_threads: 0,
      skipped_threads: 0,
      stored_unread_total: 6,
      expected_unread_total: 1,
      dry_run: true
    )
    expect(imported_conversation.communication_thread.reload.unread_count).to eq(1)
    expect(live_conversation.communication_thread.reload.unread_count).to eq(5)
  end

  it 'repairs only aggregate counters and preserves messages and seen timestamps' do
    other_account = create(:account).tap { |record| record.enable_features!('communication_threads') }
    other_conversation = create(:conversation, account: other_account, agent_last_seen_at: nil)
    create(:message, account: other_account, conversation: other_conversation, message_type: :incoming)
    other_thread = other_conversation.reload.communication_thread
    other_thread.update!(unread_count: 9)
    original_message_ids = [imported_message.id, live_message.id]
    original_live_last_seen_at = live_conversation.agent_last_seen_at

    result = described_class.new(account: account, dry_run: false).perform

    expect(result).to include(drifted_threads: 2, updated_threads: 2, skipped_threads: 0, dry_run: false)
    expect(imported_conversation.communication_thread.reload.unread_count).to eq(0)
    expect(live_conversation.communication_thread.reload.unread_count).to eq(1)
    expect(other_thread.reload.unread_count).to eq(9)
    expect(Message.where(id: original_message_ids).pluck(:id)).to match_array(original_message_ids)
    expect(imported_conversation.reload.agent_last_seen_at).to be_nil
    expect(live_conversation.reload.agent_last_seen_at).to eq(original_live_last_seen_at)
  end
end
