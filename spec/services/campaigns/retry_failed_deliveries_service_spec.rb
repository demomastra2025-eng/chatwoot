require 'rails_helper'

RSpec.describe Campaigns::RetryFailedDeliveriesService do
  subject(:service) { described_class.new(campaign: campaign) }

  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, account: account) }
  let(:inbox) { channel.inbox }
  let(:label) { create(:label, account: account, title: 'vip') }
  let!(:campaign) do
    create(:campaign, inbox: inbox, account: account, audience: [{ type: 'Label', id: label.id }])
  end

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it 'retries only failed contacts from the latest retryable run' do
    retried_contact = create(:contact, account: account, email: 'retry@example.com')
    successful_contact = create(:contact, account: account, email: 'done@example.com')
    retried_contact.update_labels([label.title])
    successful_contact.update_labels([label.title])

    source_run = create(:campaign_run, campaign: campaign, account: account, inbox: inbox, status: :failed)

    create(
      :campaign_delivery,
      campaign: campaign,
      campaign_run: source_run,
      account: account,
      inbox: inbox,
      contact: retried_contact,
      provider: 'email',
      status: :failed,
      error_message: 'mailbox unavailable'
    )
    create(
      :campaign_delivery,
      campaign: campaign,
      campaign_run: source_run,
      account: account,
      inbox: inbox,
      contact: successful_contact,
      provider: 'email',
      status: :delivered
    )

    campaign.failed!

    retried_run = service.perform

    expect(retried_run).to be_a(CampaignRun)
    expect(retried_run.reload.completed?).to be(true)
    expect(retried_run.metadata['retry_source_run_id']).to eq(source_run.id)
    expect(retried_run.total_count).to eq(1)
    expect(retried_run.processed_count).to eq(1)
    expect(campaign.reload.completed?).to be(true)
    expect(campaign.campaign_deliveries.where(contact: retried_contact).count).to eq(2)
    expect(campaign.campaign_deliveries.where(contact: successful_contact).count).to eq(1)
    expect(campaign.campaign_deliveries.find_by(campaign_run: retried_run, contact: retried_contact).status).to eq('pending')
    expect(campaign.campaign_deliveries.find_by(campaign_run: source_run, contact: retried_contact).status).to eq('failed')
    expect(enqueued_jobs.count { |job| job[:job] == SendReplyJob }).to eq(1)
  end

  it 'raises when there is no failed delivery to retry' do
    source_run = create(:campaign_run, campaign: campaign, account: account, inbox: inbox, status: :completed)
    delivered_contact = create(:contact, account: account, email: 'done@example.com')
    delivered_contact.update_labels([label.title])

    create(
      :campaign_delivery,
      campaign: campaign,
      campaign_run: source_run,
      account: account,
      inbox: inbox,
      contact: delivered_contact,
      provider: 'email',
      status: :delivered
    )

    expect { service.perform }.to raise_error('No retryable campaign run found')
  end

  it 'raises when the campaign is cancelled' do
    failed_contact = create(:contact, account: account, email: 'retry@example.com')
    failed_contact.update_labels([label.title])
    source_run = create(:campaign_run, campaign: campaign, account: account, inbox: inbox, status: :failed)

    create(
      :campaign_delivery,
      campaign: campaign,
      campaign_run: source_run,
      account: account,
      inbox: inbox,
      contact: failed_contact,
      provider: 'email',
      status: :failed
    )

    campaign.cancelled!

    expect { service.perform }.to raise_error('Cancelled campaigns cannot be retried')
  end
end
