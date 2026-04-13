require 'rails_helper'

RSpec.describe TelegramPersonal::OneoffCampaignService do
  subject(:service) { described_class.new(campaign: campaign) }

  let(:account) { create(:account) }
  let(:channel) { create(:channel_telegram_personal, account: account) }
  let(:inbox) { channel.inbox }
  let(:label) { create(:label, account: account, title: 'vip') }
  let!(:campaign) do
    create(:campaign, inbox: inbox, account: account, audience: [{ type: 'Label', id: label.id }])
  end

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it 'creates a contact inbox from the resolved telegram target and enqueues delivery' do
    contact = create(
      :contact,
      account: account,
      additional_attributes: { 'social_telegram_user_id' => '4242' }
    )
    contact.update_labels([label.title])

    service.perform

    expect(campaign.reload.completed?).to be(true)
    expect(campaign.campaign_deliveries.count).to eq(1)
    expect(campaign.campaign_deliveries.first.status).to eq('pending')
    expect(campaign.campaign_deliveries.first.provider).to eq('telegram_personal')
    expect(campaign.conversations).to be_empty
    expect(inbox.conversations.where(contact: contact).count).to eq(1)
    expect(inbox.conversations.find_by(contact: contact).contact_inbox.source_id).to eq('4242')
    expect(enqueued_jobs.count { |job| job[:job] == SendReplyJob }).to eq(1)
  end
end
