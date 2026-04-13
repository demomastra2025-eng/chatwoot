require 'rails_helper'

RSpec.describe Instagram::OneoffCampaignService do
  subject(:service) { described_class.new(campaign: campaign) }

  let(:account) { create(:account) }
  let(:channel) { create(:channel_instagram, account: account) }
  let(:inbox) { channel.inbox }
  let(:label) { create(:label, account: account, title: 'vip') }
  let!(:campaign) do
    create(:campaign, inbox: inbox, account: account, audience: [{ type: 'Label', id: label.id }])
  end

  before do
    stub_request(:post, /graph.facebook.com/).to_return(status: 200, body: '{}', headers: {})
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it 'creates a native instagram campaign conversation and enqueues delivery when an active reply window exists' do
    contact = create(:contact, account: account)
    contact.update_labels([label.title])
    contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'ig-user-1')
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, created_at: 1.hour.ago)

    service.perform

    expect(campaign.reload.completed?).to be(true)
    expect(campaign.campaign_deliveries.count).to eq(1)
    expect(campaign.campaign_deliveries.first.status).to eq('pending')
    expect(campaign.campaign_deliveries.first.provider).to eq('instagram')
    expect(campaign.conversations).to be_empty
    expect(contact_inbox.conversations.count).to eq(1)
    expect(contact_inbox.conversations.first.id).to eq(conversation.id)
    expect(contact_inbox.conversations.first.contact_inbox.source_id).to eq('ig-user-1')
    expect(enqueued_jobs.count { |job| job[:job] == SendReplyJob }).to eq(1)
  end
end
