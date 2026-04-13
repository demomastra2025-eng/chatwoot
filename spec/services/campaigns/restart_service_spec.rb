require 'rails_helper'

RSpec.describe Campaigns::RestartService do
  subject(:service) { described_class.new(campaign: campaign) }

  let(:account) { create(:account) }
  let(:channel) { create(:channel_email, account: account) }
  let(:campaign) { create(:campaign, account: account, inbox: channel.inbox, campaign_status: :failed) }

  it 'restarts a failed campaign with terminal retry enabled' do
    source_run = create(:campaign_run, campaign: campaign, account: account, inbox: campaign.inbox, status: :failed)
    restarted_run = create(:campaign_run, campaign: campaign, account: account, inbox: campaign.inbox, status: :queued)

    expect(Campaigns::OneoffRunner).to receive(:new).with(
      campaign: campaign,
      retry_source_run: source_run,
      allow_terminal_retry: true,
      restart_run: true
    ).and_return(instance_double(Campaigns::OneoffRunner, perform: restarted_run))

    expect(service.perform).to eq(restarted_run)
  end

  it 'raises for active campaigns' do
    campaign.update_column(:campaign_status, Campaign.campaign_statuses[:active])

    expect { service.perform }.to raise_error('Only failed or cancelled campaigns can be restarted')
  end
end
