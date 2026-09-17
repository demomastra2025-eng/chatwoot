require 'rails_helper'

RSpec.describe Conversations::UnreadScopeBuilder do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:user) { create(:user, account: account) }
  let(:last_seen_at) { 1.hour.ago.change(usec: 0) }

  def conversation_with_message(created_at:, **message_attributes)
    conversation = create(:conversation, account: account, inbox: inbox, agent_last_seen_at: last_seen_at)
    create(
      :message,
      account: message_attributes.delete(:account) || account,
      conversation: conversation,
      inbox: inbox,
      created_at: created_at,
      **message_attributes
    )
    conversation
  end

  it 'returns each conversation once when it has a public incoming message after last seen' do
    conversation = create(:conversation, account: account, inbox: inbox, agent_last_seen_at: last_seen_at)
    create_list(:message, 2, account: account, conversation: conversation, inbox: inbox, created_at: 10.minutes.ago)

    result = described_class.new(scope: account.conversations, account: account, user: user).perform

    expect(result.to_a).to eq([conversation])
  end

  it 'excludes old, private, outgoing, and cross-account messages' do
    old = conversation_with_message(created_at: 2.hours.ago)
    private_message = conversation_with_message(created_at: 10.minutes.ago, private: true)
    outgoing = conversation_with_message(created_at: 10.minutes.ago, message_type: :outgoing)
    cross_account = conversation_with_message(created_at: 10.minutes.ago)
    cross_account.messages.last.update_columns(account_id: create(:account).id) # rubocop:disable Rails/SkipsModelValidations

    result = described_class.new(scope: account.conversations, account: account, user: user).perform

    expect(result).not_to include(old, private_message, outgoing, cross_account)
  end

  it 'excludes imported history without rejecting malformed legacy attributes' do
    regular = conversation_with_message(created_at: 10.minutes.ago)
    serialized_history = conversation_with_message(
      created_at: 10.minutes.ago,
      content_attributes: { imported_history: true }
    )
    native_json_history = conversation_with_message(created_at: 10.minutes.ago)
    malformed_legacy = conversation_with_message(created_at: 10.minutes.ago)
    connection = Message.connection
    connection.execute(
      "UPDATE messages SET content_attributes = #{connection.quote({ imported_history: true }.to_json)}::json " \
      "WHERE id = #{native_json_history.messages.last.id}"
    )
    connection.execute(
      "UPDATE messages SET content_attributes = #{connection.quote('{legacy opaque value'.to_json)}::json " \
      "WHERE id = #{malformed_legacy.messages.last.id}"
    )

    result = described_class.new(scope: account.conversations, account: account, user: user).perform

    expect(result).to contain_exactly(regular, malformed_legacy)
    expect(result).not_to include(serialized_history, native_json_history)
  end

  it 'keeps the caller scope and uses an indexable correlated existence query' do
    included = conversation_with_message(created_at: 10.minutes.ago)
    excluded_by_scope = conversation_with_message(created_at: 5.minutes.ago)
    relation = described_class.new(scope: account.conversations.where(id: included.id), account: account, user: user).perform

    expect(relation).to contain_exactly(included)
    expect(relation).not_to include(excluded_by_scope)
    expect(relation.to_sql).to include('EXISTS ( SELECT 1 FROM messages unread_messages')
    expect(relation.to_sql).to include('json_typeof("unread_messages".content_attributes)')
    expect(relation.to_sql).not_to include('JOIN "messages"')
  end

  it 'does not hide unread messages from another user' do
    other_user = create(:user, account: account)
    conversation = conversation_with_message(created_at: 10.minutes.ago)
    create(:conversation_user_read_state, account: account, conversation: conversation, user: user, last_seen_at: Time.current)
    create(:conversation_user_read_state, account: account, conversation: conversation, user: other_user, last_seen_at: last_seen_at)

    expect(described_class.new(scope: account.conversations, account: account, user: user).perform).not_to include(conversation)
    expect(described_class.new(scope: account.conversations, account: account, user: other_user).perform).to include(conversation)
  end
end
