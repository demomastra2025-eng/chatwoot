require 'rails_helper'

RSpec.describe Telegram::OneoffCampaignService do
  subject(:service) { described_class.new(campaign: campaign) }

  let(:account) { create(:account) }
  let(:channel) { create(:channel_telegram, account: account) }
  let(:inbox) { channel.inbox }
  let(:label) { create(:label, account: account, title: 'vip') }
  let!(:campaign) do
    create(:campaign, inbox: inbox, account: account, audience: [{ type: 'Label', id: label.id }])
  end

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it 'creates a native telegram campaign conversation and preserves chat context' do
    contact = create(:contact, account: account, additional_attributes: { 'social_telegram_user_id' => '7788' })
    contact.update_labels([label.title])
    contact_inbox = create(:contact_inbox, inbox: inbox, contact: contact, source_id: '7788')
    conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      additional_attributes: { chat_id: '7788', business_connection_id: 'biz-1' }
    )

    service.perform

    expect(campaign.reload.completed?).to be(true)
    expect(campaign.campaign_deliveries.count).to eq(1)
    expect(campaign.campaign_deliveries.first.status).to eq('pending')
    expect(campaign.campaign_deliveries.first.provider).to eq('telegram')
    expect(campaign.conversations).to be_empty
    expect(contact_inbox.conversations.count).to eq(1)
    expect(contact_inbox.conversations.first.id).to eq(conversation.id)
    expect(conversation.reload.additional_attributes['chat_id']).to eq('7788')
    expect(conversation.additional_attributes['business_connection_id']).to eq('biz-1')
    expect(enqueued_jobs.count { |job| job[:job] == SendReplyJob }).to eq(1)
  end
end
