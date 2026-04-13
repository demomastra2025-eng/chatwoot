require 'rails_helper'

RSpec.describe Email::OneoffCampaignService do
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

  it 'creates native campaign conversations and pending deliveries for email contacts' do
    contact = create(:contact, account: account, email: 'vip@example.com')
    contact.update_labels([label.title])

    service.perform

    run = campaign.campaign_runs.order(:created_at).last

    expect(campaign.reload.completed?).to be(true)
    expect(run).to be_present
    expect(run.completed?).to be(true)
    expect(campaign.campaign_deliveries.count).to eq(1)
    expect(campaign.campaign_deliveries.first.status).to eq('pending')
    expect(campaign.campaign_deliveries.first.provider).to eq('email')
    expect(campaign.campaign_deliveries.first.campaign_run).to eq(run)
    expect(campaign.conversations.count).to eq(1)
    expect(campaign.conversations.first.contact_inbox.source_id).to eq('vip@example.com')
    expect(enqueued_jobs.count { |job| job[:job] == SendReplyJob }).to eq(1)
  end

  it 'stops scheduling new contacts when the running campaign is cancelled' do
    first_contact = create(:contact, account: account, email: 'first@example.com')
    second_contact = create(:contact, account: account, email: 'second@example.com')
    first_contact.update_labels([label.title])
    second_contact.update_labels([label.title])

    allow_any_instance_of(Campaigns::OneoffConversationBuilder).to receive(:perform).and_wrap_original do |method, *args|
      message = method.call(*args)
      campaign.cancel_one_off! unless campaign.reload.cancelled?
      message
    end

    service.perform

    run = campaign.campaign_runs.order(:created_at).last

    expect(campaign.reload.cancelled?).to be(true)
    expect(run.reload.cancelled?).to be(true)
    expect(campaign.campaign_deliveries.count).to eq(1)
    expect(enqueued_jobs.count { |job| job[:job] == SendReplyJob }).to eq(1)
  end

  it 'allows terminal retry execution from cancelled campaigns' do
    contact = create(:contact, account: account, email: 'retry@example.com')
    contact.update_labels([label.title])
    campaign.cancelled!

    described_class.new(campaign: campaign, allow_terminal_retry: true).perform

    run = campaign.campaign_runs.order(:created_at).last

    expect(campaign.reload.completed?).to be(true)
    expect(run).to be_present
    expect(run.completed?).to be(true)
    expect(run.successful_count).to eq(1)
    expect(campaign.conversations.count).to eq(1)
    expect(campaign.conversations.first.messages.outgoing.count).to eq(1)
  end

  it 'creates a new outbound message when retrying a cancelled campaign' do
    contact = create(:contact, account: account, email: 'retry@example.com')
    contact.update_labels([label.title])

    service.perform
    campaign.cancelled!

    described_class.new(campaign: campaign, allow_terminal_retry: true).perform

    expect(campaign.conversations.count).to eq(1)
    expect(campaign.conversations.first.messages.outgoing.count).to eq(2)
    expect(enqueued_jobs.count { |job| job[:job] == SendReplyJob }).to eq(2)
  end

  it 'finalizes campaign status from the current run instead of historical deliveries' do
    delivered_contact = create(:contact, account: account, email: 'sent@example.com')
    failing_contact = create(:contact, account: account, email: 'fail@example.com')
    delivered_contact.update_labels([label.title])
    failing_contact.update_labels([label.title])

    previous_run = create(
      :campaign_run,
      campaign: campaign,
      account: account,
      inbox: inbox,
      status: :completed
    )
    create(
      :campaign_delivery,
      campaign: campaign,
      campaign_run: previous_run,
      account: account,
      inbox: inbox,
      contact: delivered_contact,
      provider: 'email',
      status: :delivered
    )
    campaign.failed!

    allow_any_instance_of(Campaigns::OneoffConversationBuilder).to receive(:perform)
      .and_raise(StandardError, 'mailbox unavailable')

    described_class.new(
      campaign: campaign,
      contact_ids: [failing_contact.id],
      allow_terminal_retry: true
    ).perform

    latest_run = campaign.campaign_runs.order(:created_at).last
    latest_delivery = campaign.campaign_deliveries.find_by(
      campaign_run: latest_run,
      contact: failing_contact
    )

    expect(latest_run).to be_present
    expect(latest_run).not_to eq(previous_run)
    expect(latest_delivery.status).to eq('failed')
    expect(campaign.reload.failed?).to be(true)
  end

  it 'marks the campaign as failed when execution crashes after switching to running' do
    contact = create(:contact, account: account, email: 'retry@example.com')
    contact.update_labels([label.title])

    allow(Campaigns::AudienceResolver).to receive(:new).and_raise(StandardError, 'resolver crashed')

    expect { service.perform }.to raise_error(StandardError, 'resolver crashed')

    run = campaign.campaign_runs.order(:created_at).last

    expect(run).to be_present
    expect(run.failed?).to be(true)
    expect(campaign.reload.failed?).to be(true)
  end
end
