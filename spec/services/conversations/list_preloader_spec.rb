require 'rails_helper'

RSpec.describe Conversations::ListPreloader do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:user) { create(:user, account: account) }
  let(:seen_at) { 1.day.ago.change(usec: 0) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, agent_last_seen_at: seen_at) }

  def load_list(records = [conversation])
    described_class.new(account: account, conversations: Conversation.where(id: records.map(&:id)), user: user).perform
  end

  def message_at(time, **attributes)
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     sender: conversation.contact, message_type: :incoming, created_at: time, **attributes)
  end

  it 'matches message, unread and reply-window semantics without reading private previews' do
    message_at(seen_at - 1.second)
    message_at(seen_at)
    newest_chat = message_at(seen_at + 1.hour)
    newest_public = message_at(seen_at + 2.hours, message_type: :activity)
    message_at(seen_at + 3.hours, private: true)
    data = load_list

    expect(data.last_message(conversation)).to eq(newest_public)
    expect(data.last_non_activity_message(conversation)).to eq(newest_chat)
    expect(data.unread_count(conversation)).to eq(conversation.unread_incoming_messages_count)
    expect(data.unread_count(conversation)).to eq(1)
    expect(data.can_reply?(conversation)).to eq(conversation.can_reply?)
  end

  it 'counts all public incoming messages when last seen is nil, including pre-epoch imports' do
    conversation.update!(agent_last_seen_at: nil)
    message_at(Time.zone.at(-1))
    message_at(seen_at)
    expect(load_list.unread_count(conversation)).to eq(2)
  end

  it 'returns no preview and zero unread for an empty conversation' do
    data = load_list
    expect(data.last_message(conversation)).to be_nil
    expect(data.last_non_activity_message(conversation)).to be_nil
    expect(data.message_payload(nil)).to be_nil
    expect(data.unread_count(conversation)).to eq(0)
  end

  it 'has no SQL work for an empty page' do
    account
    user
    expect(sql_count { described_class.new(account: account, conversations: [], user: user).perform }).to eq(0)
  end

  it 'selects the higher message id on equal timestamps' do
    message_at(seen_at)
    last = message_at(seen_at)
    expect(load_list.last_message(conversation)).to eq(last)
    expect(load_list.last_non_activity_message(conversation)).to eq(last)
  end

  it 'unions contact and conversation labels without losing label order' do
    conversation.contact.update!(label_list: %w[zeta shared])
    conversation.update!(label_list: %w[shared alpha])
    expected = Labels::UnifiedAssignmentService.union_for(contact: conversation.contact.reload, conversations: [conversation.reload])
    expect(load_list.labels(conversation)).to eq(expected)
  end

  it 'rejects a conversation from another account' do
    other = create(:conversation)
    expect { described_class.new(account: account, conversations: [other], user: user) }
      .to raise_error(ArgumentError, 'Conversation account mismatch')
  end

  it 'excludes a message with a mismatched account' do
    legitimate = message_at(seen_at)
    corrupt = message_at(seen_at + 1.hour)
    corrupt.update_columns(account_id: create(:account).id) # rubocop:disable Rails/SkipsModelValidations -- deliberately corrupt legacy data
    data = load_list
    expect(data.last_message(conversation)).to eq(legitimate)
    expect(data.unread_count(conversation)).to eq(0)
  end

  it 'keeps the original message inbox after a conversation moves' do
    original_message = message_at(seen_at)
    conversation.update_columns(inbox_id: create(:inbox, account: account).id) # rubocop:disable Rails/SkipsModelValidations -- historical inbox mismatch
    data = load_list
    expect(data.last_message(conversation).inbox).to eq(original_message.inbox)
  end

  it 'returns unread state for the current user' do
    other_user = create(:user, account: account)
    message_at(seen_at + 1.hour)
    create(:conversation_user_read_state, account: account, conversation: conversation, user: user, last_seen_at: seen_at + 2.hours)
    create(:conversation_user_read_state, account: account, conversation: conversation, user: other_user, last_seen_at: seen_at)

    current_user_data = load_list
    other_user_data = described_class.new(account: account, conversations: [conversation], user: other_user).perform

    expect(current_user_data.unread_count(conversation)).to eq(0)
    expect(current_user_data.last_seen_at(conversation)).to eq(seen_at + 2.hours)
    expect(other_user_data.unread_count(conversation)).to eq(1)
    expect(other_user_data.last_seen_at(conversation)).to eq(seen_at)
  end

  it 'serializes the same message once without changing its realtime unread behavior' do
    message = message_at(seen_at + 1.hour)
    data = load_list
    loaded = data.last_message(conversation)
    allow(loaded).to receive(:push_event_data).and_call_original
    expect(data.message_payload(loaded)).to eq(message.reload.push_event_data)
    expect(data.message_payload(data.last_non_activity_message(conversation))).to eq(message.push_event_data)
    expect(loaded).to have_received(:push_event_data).once

    conversation.update!(agent_last_seen_at: seen_at + 2.hours)
    expect(load_list.unread_count(conversation)).to eq(0)
    expect(message.reload.push_event_data.dig(:conversation, :unread_count)).to eq(0)
  end

  it 'uses a bounded number of queries as the page grows' do
    records = create_list(:conversation, 4, account: account, inbox: inbox)
    records.each { |record| create(:message, account: account, inbox: inbox, conversation: record, sender: record.contact) }
    load_list(records) # Warm schema metadata, not the record instances used below.
    small = sql_count { load_list(records.first(2)) }
    large = sql_count { load_list(records) }
    expect(large).to eq(small)
  end

  def sql_count(&)
    count = 0
    subscriber = lambda do |*args|
      payload = args.last
      count += 1 unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &)
    count
  end
end
