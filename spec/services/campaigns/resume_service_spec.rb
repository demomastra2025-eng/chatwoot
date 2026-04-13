require 'rails_helper'

RSpec.describe Campaigns::ResumeService do
  subject(:service) { described_class.new(campaign: campaign) }

  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, account: account) }
  let(:label) { create(:label, account: account, title: 'vip') }
  let(:campaign) do
    create(
      :campaign,
      account: account,
      inbox: channel.inbox,
      audience: [{ type: 'Label', id: label.id }],
      campaign_status: :cancelled
    )
  end

  it 'resumes only contacts that were not processed in the interrupted run' do
    processed_contact = create(:contact, account: account, email: 'done@example.com')
    remaining_contact = create(:contact, account: account, email: 'pending@example.com')
    processed_contact.update_labels([label.title])
    remaining_contact.update_labels([label.title])

    source_run = create(:campaign_run, campaign: campaign, account: account, inbox: campaign.inbox, status: :cancelled)
    create(
      :campaign_delivery,
      campaign: campaign,
      campaign_run: source_run,
      account: account,
      inbox: campaign.inbox,
      contact: processed_contact,
      provider: 'email',
      status: :pending
    )

    resumed_run = create(:campaign_run, campaign: campaign, account: account, inbox: campaign.inbox, status: :queued)

    expect(Campaigns::OneoffRunner).to receive(:new).with(
      campaign: campaign,
      contact_ids: [remaining_contact.id],
      retry_source_run: source_run,
      allow_terminal_retry: true,
      resume_run: true
    ).and_return(instance_double(Campaigns::OneoffRunner, perform: resumed_run))

    expect(service.perform).to eq(resumed_run)
  end

  it 'raises when there are no remaining contacts to resume' do
    contact = create(:contact, account: account, email: 'done@example.com')
    contact.update_labels([label.title])

    source_run = create(:campaign_run, campaign: campaign, account: account, inbox: campaign.inbox, status: :cancelled)
    create(
      :campaign_delivery,
      campaign: campaign,
      campaign_run: source_run,
      account: account,
      inbox: campaign.inbox,
      contact: contact,
      provider: 'email',
      status: :pending
    )

    expect { service.perform }.to raise_error('No remaining contacts to resume')
  end
end
