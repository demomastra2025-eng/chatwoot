# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversations::SidebarUnreadCountService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:inbox) { create(:inbox, account: account) }

  before { create(:inbox_member, user: user, inbox: inbox) }

  it 'returns empty teams unread counts now that teams are removed' do
    live_conversation = create(:conversation, account: account, inbox: inbox, agent_last_seen_at: 1.day.ago)
    create(:message, account: account, conversation: live_conversation, message_type: :incoming, created_at: 1.hour.ago)

    result = described_class.new(account: account, user: user).perform

    expect(result[:teams]).to eq({})
  end

  it 'keeps every uncounted dimension in the payload as an empty value' do
    conversation = create(:conversation, account: account, inbox: inbox, agent_last_seen_at: 1.day.ago)
    conversation.update_labels('vip')
    create(:message, account: account, conversation: conversation, message_type: :incoming, created_at: 1.hour.ago)

    result = described_class.new(account: account, user: user).perform

    expect(result).to eq(
      all: 0,
      statuses: {},
      inboxes: {},
      teams: {},
      labels: {},
      pipelines: {},
      stages: {},
      appointment_statuses: {}
    )
  end
end
