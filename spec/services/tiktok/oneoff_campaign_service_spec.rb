require 'rails_helper'

RSpec.describe Tiktok::OneoffCampaignService do
  subject(:service) { described_class.new(campaign: campaign) }

  let(:account) { create(:account) }
  let(:channel) { create(:channel_tiktok, account: account) }
  let(:inbox) { channel.inbox }
  let(:label) { create(:label, account: account, title: 'vip') }
  let!(:campaign) do
    create(:campaign, inbox: inbox, account: account, audience: [{ type: 'Label', id: label.id }])
  end

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it 'creates a native tiktok campaign conversation when the reply window is active' do
    contact = create(:contact, account: account)
    contact.update_labels([label.title])
    contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'tt-conv-1')
    conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      additional_attributes: { conversation_id: 'tt-conv-1' }
    )
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      sender: contact,
      message_type: :incoming,
      created_at: 1.hour.ago
    )

    service.perform

    expect(campaign.reload.completed?).to be(true)
    expect(campaign.campaign_deliveries.count).to eq(1)
    expect(campaign.campaign_deliveries.first.status).to eq('pending')
    expect(campaign.campaign_deliveries.first.provider).to eq('tiktok')
    expect(campaign.conversations).to be_empty
    expect(contact_inbox.conversations.count).to eq(1)
    expect(contact_inbox.conversations.first.id).to eq(conversation.id)
    expect(contact_inbox.conversations.first.additional_attributes['conversation_id']).to eq('tt-conv-1')
    expect(enqueued_jobs.count { |job| job[:job] == SendReplyJob }).to eq(1)
  end

  it 'skips contacts outside the active tiktok reply window' do
    contact = create(:contact, account: account)
    contact.update_labels([label.title])
    contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'tt-conv-2')
    conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      additional_attributes: { conversation_id: 'tt-conv-2' }
    )
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      sender: contact,
      message_type: :incoming,
      created_at: 3.days.ago
    )

    service.perform

    expect(campaign.reload.failed?).to be(true)
    expect(campaign.campaign_deliveries.count).to eq(1)
    expect(campaign.campaign_deliveries.first.status).to eq('skipped')
    expect(campaign.campaign_deliveries.first.error_message).to eq('Contact has no active reply window for this inbox')
    expect(enqueued_jobs.count { |job| job[:job] == SendReplyJob }).to eq(0)
  end
end
