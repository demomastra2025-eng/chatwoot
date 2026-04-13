require 'rails_helper'

RSpec.describe CampaignRun do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:campaign) }
    it { is_expected.to belong_to(:inbox) }
    it { is_expected.to have_many(:campaign_deliveries).dependent(:nullify) }
  end

  describe '#start!' do
    let(:campaign_run) { create(:campaign_run) }

    it 'transitions the run to running and resets counters' do
      campaign_run.update!(status: :failed, error_message: 'boom', processed_count: 9, failed_count: 9)

      campaign_run.start!(total_count: 12, metadata: { provider: 'sms' })

      expect(campaign_run.reload.running?).to be(true)
      expect(campaign_run.total_count).to eq(12)
      expect(campaign_run.processed_count).to eq(0)
      expect(campaign_run.failed_count).to eq(0)
      expect(campaign_run.error_message).to be_nil
      expect(campaign_run.metadata['provider']).to eq('sms')
      expect(campaign_run.started_at).to be_present
    end
  end

  describe '#complete_from_deliveries!' do
    let(:campaign) { create(:campaign) }
    let(:campaign_run) { create(:campaign_run, campaign: campaign, account: campaign.account, inbox: campaign.inbox, status: :running) }

    it 'stores a delivery snapshot for the completed run' do
      create(:campaign_delivery, campaign: campaign, campaign_run: campaign_run, account: campaign.account, inbox: campaign.inbox, status: :submitted)
      create(:campaign_delivery, campaign: campaign, campaign_run: campaign_run, account: campaign.account, inbox: campaign.inbox, status: :failed)
      create(:campaign_delivery, campaign: campaign, campaign_run: campaign_run, account: campaign.account, inbox: campaign.inbox, status: :skipped)

      campaign_run.complete_from_deliveries!(audience_size: 5)

      expect(campaign_run.reload.completed?).to be(true)
      expect(campaign_run.total_count).to eq(5)
      expect(campaign_run.processed_count).to eq(3)
      expect(campaign_run.successful_count).to eq(1)
      expect(campaign_run.failed_count).to eq(1)
      expect(campaign_run.skipped_count).to eq(1)
      expect(campaign_run.completed_at).to be_present
    end

    it 'marks the run failed when no delivery succeeded' do
      create(:campaign_delivery, campaign: campaign, campaign_run: campaign_run, account: campaign.account, inbox: campaign.inbox, status: :failed)
      create(:campaign_delivery, campaign: campaign, campaign_run: campaign_run, account: campaign.account, inbox: campaign.inbox, status: :skipped)

      campaign_run.complete_from_deliveries!(audience_size: 2)

      expect(campaign_run.reload.failed?).to be(true)
      expect(campaign_run.processed_count).to eq(2)
      expect(campaign_run.successful_count).to eq(0)
      expect(campaign_run.failed_count).to eq(1)
      expect(campaign_run.skipped_count).to eq(1)
      expect(campaign_run.error_message).to eq('No deliveries succeeded')
    end
  end

  describe '#fail!' do
    let(:campaign) { create(:campaign) }
    let(:campaign_run) { create(:campaign_run, campaign: campaign, account: campaign.account, inbox: campaign.inbox, status: :running) }

    it 'marks the run failed while preserving current delivery counters' do
      create(:campaign_delivery, campaign: campaign, campaign_run: campaign_run, account: campaign.account, inbox: campaign.inbox, status: :submitted)
      create(:campaign_delivery, campaign: campaign, campaign_run: campaign_run, account: campaign.account, inbox: campaign.inbox, status: :failed)

      campaign_run.fail!('provider exploded', audience_size: 4)

      expect(campaign_run.reload.failed?).to be(true)
      expect(campaign_run.error_message).to eq('provider exploded')
      expect(campaign_run.total_count).to eq(4)
      expect(campaign_run.processed_count).to eq(2)
      expect(campaign_run.successful_count).to eq(1)
      expect(campaign_run.failed_count).to eq(1)
      expect(campaign_run.completed_at).to be_present
    end
  end

  describe '#cancel!' do
    let(:campaign) { create(:campaign) }
    let(:campaign_run) { create(:campaign_run, campaign: campaign, account: campaign.account, inbox: campaign.inbox, status: :running) }

    it 'marks the run cancelled while preserving current delivery counters' do
      create(:campaign_delivery, campaign: campaign, campaign_run: campaign_run, account: campaign.account, inbox: campaign.inbox, status: :submitted)
      create(:campaign_delivery, campaign: campaign, campaign_run: campaign_run, account: campaign.account, inbox: campaign.inbox, status: :failed)

      campaign_run.cancel!('stopped by operator', audience_size: 4)

      expect(campaign_run.reload.cancelled?).to be(true)
      expect(campaign_run.error_message).to eq('stopped by operator')
      expect(campaign_run.total_count).to eq(4)
      expect(campaign_run.processed_count).to eq(2)
      expect(campaign_run.successful_count).to eq(1)
      expect(campaign_run.failed_count).to eq(1)
      expect(campaign_run.completed_at).to be_present
    end
  end

  describe '#refresh_delivery_snapshot!' do
    let(:campaign) { create(:campaign) }
    let(:campaign_run) do
      create(
        :campaign_run,
        campaign: campaign,
        account: campaign.account,
        inbox: campaign.inbox,
        status: :completed,
        total_count: 4,
        processed_count: 1,
        successful_count: 1,
        failed_count: 0,
        skipped_count: 0
      )
    end

    it 'recalculates counters from current delivery statuses without changing the run status' do
      delivery = create(
        :campaign_delivery,
        campaign: campaign,
        campaign_run: campaign_run,
        account: campaign.account,
        inbox: campaign.inbox,
        status: :submitted
      )
      create(
        :campaign_delivery,
        campaign: campaign,
        campaign_run: campaign_run,
        account: campaign.account,
        inbox: campaign.inbox,
        status: :failed
      )

      delivery.update!(status: :delivered)
      campaign_run.refresh_delivery_snapshot!

      expect(campaign_run.reload.completed?).to be(true)
      expect(campaign_run.processed_count).to eq(2)
      expect(campaign_run.successful_count).to eq(1)
      expect(campaign_run.failed_count).to eq(1)
      expect(campaign_run.skipped_count).to eq(0)
    end
  end
end
