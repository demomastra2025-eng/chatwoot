# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversations::SidebarUnreadCountService do
  it 'excludes imported history from sidebar unread counts' do
    account = create(:account)
    user = create(:user, account: account, role: :administrator)
    inbox = create(:inbox, account: account)
    create(:inbox_member, user: user, inbox: inbox)
    live_conversation = create(:conversation, account: account, inbox: inbox, agent_last_seen_at: 1.day.ago)
    history_conversation = create(:conversation, account: account, inbox: inbox, agent_last_seen_at: nil)
    create(:message, account: account, conversation: live_conversation, message_type: :incoming, created_at: 1.hour.ago)
    create(
      :message,
      account: account,
      conversation: history_conversation,
      message_type: :incoming,
      content_attributes: { imported_history: true },
      created_at: 2.days.ago
    )

    result = described_class.new(account: account, user: user).perform

    expect(result).to include(
      all: 1,
      statuses: include('open' => 1),
      inboxes: include(inbox.id.to_s => 1)
    )
  end
end
