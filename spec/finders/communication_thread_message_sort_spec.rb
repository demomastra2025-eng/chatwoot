require 'rails_helper'

RSpec.describe CommunicationThreadFinder do # rubocop:disable RSpec/SpecFilePathFormat -- focused sorting regression suite
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:base_time) { 2.days.ago.change(usec: 0) }

  before { account.enable_features!('communication_threads') }

  def sort_time(thread, scope = account.conversations)
    CommunicationThreadFinder.with_last_message_activity_sort(CommunicationThread.where(account_id: account.id, id: thread.id), scope)
                             .first[:last_message_activity_sort_at]
  end

  def add_message(record, time, **attributes)
    create(:message, account: record.account, conversation: record, inbox: record.inbox, created_at: time, **attributes)
  end

  it 'uses the latest public non-activity message and observes edits and deletions immediately' do
    older = add_message(conversation, base_time, message_type: :incoming)
    newer = add_message(conversation, base_time + 1.hour, message_type: :outgoing)
    add_message(conversation, base_time + 2.hours, message_type: :activity)
    add_message(conversation, base_time + 3.hours, message_type: :outgoing, private: true)
    thread = conversation.reload.communication_thread
    expect(sort_time(thread)).to eq(newer.created_at)

    older.update_columns(created_at: base_time + 4.hours) # rubocop:disable Rails/SkipsModelValidations -- simulate edits without refreshing aggregates
    expect(sort_time(thread)).to eq(older.created_at)
    older.delete
    expect(sort_time(thread)).to eq(newer.created_at)
  end

  it 'falls back to thread creation when there is no eligible message' do
    add_message(conversation, base_time, message_type: :activity)
    thread = conversation.reload.communication_thread
    expect(sort_time(thread)).to eq(thread.created_at)
  end

  it 'aggregates only visible linked conversations and observes unlinking' do
    first = add_message(conversation, base_time, message_type: :incoming)
    other = create(:conversation, account: account, contact: conversation.contact)
    latest = add_message(other, base_time + 1.hour, message_type: :outgoing)
    thread = conversation.reload.communication_thread
    expect(other.reload.communication_thread).to eq(thread)
    expect(sort_time(thread)).to eq(latest.created_at)
    expect(sort_time(thread, account.conversations.where(id: conversation.id))).to eq(first.created_at)

    other.communication_thread_conversation.delete
    expect(sort_time(thread)).to eq(first.created_at)
  end

  it 'does not use a cross-account message even when it references an accessible conversation' do
    valid = add_message(conversation, base_time, message_type: :incoming)
    invalid = add_message(conversation, base_time + 1.hour, message_type: :incoming)
    invalid.update_columns(account_id: create(:account).id) # rubocop:disable Rails/SkipsModelValidations -- deliberately corrupt legacy data
    expect(sort_time(conversation.reload.communication_thread)).to eq(valid.created_at)
  end

  it 'preserves ascending, descending and stable thread id tie ordering' do
    records = create_list(:conversation, 3, account: account)
    records.each { |record| add_message(record, base_time, message_type: :incoming) }
    threads = records.map { |record| record.reload.communication_thread }
    %w[asc desc].each do |direction|
      relation = described_class.with_last_message_activity_sort(
        CommunicationThread.where(account_id: account.id, id: threads.map(&:id)), account.conversations
      ).order(Arel.sql(CommunicationThreadFinder::SORT_OPTIONS.fetch("last_activity_at_#{direction}")))
      expected = threads.map(&:id).sort
      expected.reverse! if direction == 'desc'
      expect(relation.map(&:id)).to eq(expected)
    end
  end

  it 'looks up indexed public messages only for threads that survive the outer filters' do
    thread = conversation.reload.communication_thread
    relation = described_class.with_last_message_activity_sort(
      CommunicationThread.where(account_id: account.id, id: thread.id), account.conversations
    )

    sql = relation.to_sql
    expect(sql).to include('LEFT JOIN LATERAL')
    expect(sql).to include('sort_thread_links.communication_thread_id = communication_threads.id')
    expect(sql).to include('INNER JOIN LATERAL')
    expect(sql).to match(/ORDER BY messages\.created_at DESC LIMIT 1/)
    expect(sql).not_to include('GROUP BY sort_thread_links.account_id')
  end

  it 'does not multiply the outer thread scope by linked conversations' do
    user = create(:user, account: account)
    create(:inbox_member, user: user, inbox: conversation.inbox)
    Current.account = account

    relation = described_class.new(user, status: 'all', include_meta: false).perform[:communication_threads]

    expect(relation.to_sql).not_to include('INNER JOIN "communication_thread_conversations"')
    expect(relation.to_sql).to include('"communication_threads"."id" IN')
  end
end
