# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversations::SidebarUnreadCountService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:inbox) { create(:inbox, account: account) }
  let(:team) { create(:team, account: account) }

  before { create(:inbox_member, user: user, inbox: inbox) }

  it 'excludes imported history from the team unread counts' do
    live_conversation = create(:conversation, account: account, inbox: inbox, team: team, agent_last_seen_at: 1.day.ago)
    history_conversation = create(:conversation, account: account, inbox: inbox, team: team, agent_last_seen_at: nil)
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

    expect(result[:teams]).to eq(team.id.to_s => 1)
  end

  it 'keeps every uncounted dimension in the payload as an empty value' do
    conversation = create(:conversation, account: account, inbox: inbox, team: team, agent_last_seen_at: 1.day.ago)
    conversation.update_labels('vip')
    create(:message, account: account, conversation: conversation, message_type: :incoming, created_at: 1.hour.ago)

    result = described_class.new(account: account, user: user).perform

    expect(result).to eq(
      all: 0,
      statuses: {},
      inboxes: {},
      teams: { team.id.to_s => 1 },
      labels: {},
      pipelines: {},
      stages: {},
      appointment_statuses: {}
    )
  end

  it 'counts only the conversations the agent can access' do
    agent = create(:user, account: account, role: :agent)
    other_inbox = create(:inbox, account: account)
    create(:inbox_member, user: agent, inbox: inbox)
    visible = create(:conversation, account: account, inbox: inbox, team: team, agent_last_seen_at: 1.day.ago)
    hidden = create(:conversation, account: account, inbox: other_inbox, team: team, agent_last_seen_at: 1.day.ago)
    [visible, hidden].each do |conversation|
      create(:message, account: account, conversation: conversation, message_type: :incoming, created_at: 1.hour.ago)
    end

    expect(described_class.new(account: account, user: agent).perform[:teams]).to eq(team.id.to_s => 1)
    expect(described_class.new(account: account, user: user).perform[:teams]).to eq(team.id.to_s => 2)
  end
end
