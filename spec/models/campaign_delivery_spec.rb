require 'rails_helper'

RSpec.describe CampaignDelivery do
  describe 'campaign run snapshot sync' do
    let(:account) { create(:account) }
    let(:channel) { create(:channel_email, account: account) }
    let(:campaign) { create(:campaign, account: account, inbox: channel.inbox, campaign_status: :completed) }
    let(:campaign_run) do
      create(
        :campaign_run,
        campaign: campaign,
        account: campaign.account,
        inbox: campaign.inbox,
        status: :completed,
        total_count: 3
      )
    end

    it 'refreshes the associated campaign run and latest campaign status after status updates' do
      delivery = create(
        :campaign_delivery,
        campaign: campaign,
        campaign_run: campaign_run,
        account: campaign.account,
        inbox: campaign.inbox,
        status: :submitted
      )

      expect(campaign_run.reload.processed_count).to eq(1)
      expect(campaign_run.successful_count).to eq(1)
      expect(campaign.reload.completed?).to be(true)

      delivery.mark_status!(status: :failed, error_message: 'provider rejected')

      expect(campaign_run.reload.processed_count).to eq(1)
      expect(campaign_run.successful_count).to eq(0)
      expect(campaign_run.failed_count).to eq(1)
      expect(campaign_run.failed?).to be(true)
      expect(campaign.reload.failed?).to be(true)
    end

    it 'restores latest run and campaign status when provider delivery updates become successful later' do
      delivery = create(
        :campaign_delivery,
        campaign: campaign,
        campaign_run: campaign_run,
        account: campaign.account,
        inbox: campaign.inbox,
        status: :failed
      )
      campaign_run.update!(status: :failed, error_message: 'provider rejected')
      campaign.update_column(:campaign_status, Campaign.campaign_statuses[:failed])

      delivery.mark_status!(status: :delivered)

      expect(campaign_run.reload.completed?).to be(true)
      expect(campaign_run.successful_count).to eq(1)
      expect(campaign_run.failed_count).to eq(0)
      expect(campaign.reload.completed?).to be(true)
    end
  end
end
