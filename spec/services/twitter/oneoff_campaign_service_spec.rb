require 'rails_helper'

RSpec.describe Twitter::OneoffCampaignService do
  subject(:service) { described_class.new(campaign: campaign) }

  let(:account) { create(:account) }
  let(:channel) { create(:channel_twitter_profile, account: account) }
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:label) { create(:label, account: account, title: 'vip') }
  let!(:campaign) do
    create(:campaign, inbox: inbox, account: account, audience: [{ type: 'Label', id: label.id }])
  end

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it 'creates a native twitter direct-message campaign conversation and enqueues delivery' do
    contact = create(:contact, account: account)
    contact.update_labels([label.title])
    contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'tw-user-1')
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      additional_attributes: { type: 'direct_message' }
    )

    service.perform

    expect(campaign.reload.completed?).to be(true)
    expect(campaign.campaign_deliveries.count).to eq(1)
    expect(campaign.campaign_deliveries.first.status).to eq('pending')
    expect(campaign.campaign_deliveries.first.provider).to eq('twitter')
    expect(campaign.conversations.count).to eq(1)
    expect(campaign.conversations.first.additional_attributes['type']).to eq('direct_message')
    expect(enqueued_jobs.count { |job| job[:job] == SendReplyJob }).to eq(1)
  end

  it 'does not treat tweet-only contacts as deliverable outbound targets' do
    contact = create(:contact, account: account)
    contact.update_labels([label.title])
    contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'tw-user-2')
    create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      additional_attributes: { type: 'tweet', tweet_id: '12345' }
    )

    service.perform

    expect(campaign.reload.failed?).to be(true)
    expect(campaign.campaign_deliveries.count).to eq(1)
    expect(campaign.campaign_deliveries.first.status).to eq('skipped')
    expect(campaign.campaign_deliveries.first.error_message).to eq('Contact has no deliverable target for this inbox')
    expect(enqueued_jobs.count { |job| job[:job] == SendReplyJob }).to eq(0)
  end
end
