require 'rails_helper'

RSpec.describe Facebook::OneoffCampaignService do
  subject(:service) { described_class.new(campaign: campaign) }

  let(:account) { create(:account) }
  let(:channel) { create(:channel_facebook_page, account: account, inbox: nil) }
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:label) { create(:label, account: account, title: 'vip') }
  let(:campaign) do
    create(:campaign, inbox: inbox, account: account, audience: [{ type: 'Label', id: label.id }])
  end

  before do
    stub_request(:post, 'https://graph.facebook.com/v3.2/me/subscribed_apps').to_return(status: 200, body: '{}', headers: {})
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it 'creates a native messenger campaign conversation and enqueues delivery when an active reply window exists' do
    contact = create(:contact, account: account)
    contact.update_labels([label.title])
    contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'fb-user-1')
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, created_at: 1.hour.ago)

    service.perform

    expect(campaign.reload.completed?).to be(true)
    expect(campaign.campaign_deliveries.count).to eq(1)
    expect(campaign.campaign_deliveries.first.status).to eq('pending')
    expect(campaign.campaign_deliveries.first.provider).to eq('facebook')
    expect(campaign.conversations).to be_empty
    expect(contact_inbox.conversations.count).to eq(1)
    expect(contact_inbox.conversations.first.id).to eq(conversation.id)
    expect(contact_inbox.conversations.first.contact_inbox.source_id).to eq('fb-user-1')
    expect(enqueued_jobs.count { |job| job[:job] == SendReplyJob }).to eq(1)
  end

  it 'skips contacts outside the active reply window' do
    contact = create(:contact, account: account)
    contact.update_labels([label.title])
    create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'fb-user-2')

    service.perform

    expect(campaign.reload.failed?).to be(true)
    expect(campaign.campaign_deliveries.count).to eq(1)
    expect(campaign.campaign_deliveries.first.status).to eq('skipped')
    expect(campaign.campaign_deliveries.first.error_message).to eq('Contact has no active reply window for this inbox')
    expect(enqueued_jobs.count { |job| job[:job] == SendReplyJob }).to eq(0)
  end
end
