require 'rails_helper'

RSpec.describe WhatsappWeb::ConversationSyncService do
  let(:channel) { create(:channel_whatsapp_web) }
  let(:contact) { create(:contact, account: channel.account) }
  let(:contact_inbox) do
    create(
      :contact_inbox,
      contact: contact,
      inbox: channel.inbox,
      source_id: '15551234567'
    )
  end

  it 'creates imported conversations as read by default' do
    activity_at = 2.hours.ago.change(usec: 0)

    conversation = described_class.new(
      channel: channel,
      contact_inbox: contact_inbox,
      activity_at: activity_at
    ).perform

    expect(conversation.agent_last_seen_at).to be_within(1.second).of(activity_at)
    expect(conversation.assignee_last_seen_at).to be_within(1.second).of(activity_at)
    expect(conversation.last_activity_at).to be_within(1.second).of(activity_at)
  end
end
