require 'rails_helper'

RSpec.describe Line::OneoffCampaignService do
  subject(:service) { described_class.new(campaign: campaign) }

  let(:account) { create(:account) }
  let(:channel) { create(:channel_line, account: account, inbox: nil) }
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:label) { create(:label, account: account, title: 'vip') }
  let!(:campaign) do
    create(:campaign, inbox: inbox, account: account, audience: [{ type: 'Label', id: label.id }])
  end

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it 'creates a native line campaign conversation and enqueues delivery' do
    contact = create(:contact, account: account)
    contact.update_labels([label.title])
    create(:contact_inbox, inbox: inbox, contact: contact, source_id: 'line-user-1')

    service.perform

    expect(campaign.reload.completed?).to be(true)
    expect(campaign.campaign_deliveries.count).to eq(1)
    expect(campaign.campaign_deliveries.first.status).to eq('pending')
    expect(campaign.campaign_deliveries.first.provider).to eq('line')
    expect(campaign.conversations).to be_empty
    expect(inbox.conversations.where(contact: contact).count).to eq(1)
    expect(inbox.conversations.find_by(contact: contact).contact_inbox.source_id).to eq('line-user-1')
    expect(enqueued_jobs.count { |job| job[:job] == SendReplyJob }).to eq(1)
  end
end
