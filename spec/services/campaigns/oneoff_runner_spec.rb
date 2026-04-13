require 'rails_helper'

RSpec.describe Campaigns::OneoffRunner do
  subject(:runner) { described_class.new(campaign: campaign) }

  describe '#perform' do
    context 'when campaign inbox is Sms' do
      let(:account) { create(:account) }
      let(:channel) { create(:channel_sms, account: account) }
      let(:campaign) { create(:campaign, account: account, inbox: channel.inbox) }

      it 'dispatches to Sms oneoff service' do
        service = instance_double(Sms::OneoffSmsCampaignService, perform: true)

        expect(Sms::OneoffSmsCampaignService).to receive(:new) do |**kwargs|
          service_campaign = kwargs[:campaign]
          run = kwargs[:campaign_run]
          expect(service_campaign).to eq(campaign)
          expect(run).to be_a(CampaignRun)
          expect(run.campaign).to eq(campaign)
          service
        end

        runner.perform
      end
    end

    context 'when campaign inbox is Twilio SMS' do
      let(:account) { create(:account) }
      let(:channel) { create(:channel_twilio_sms, account: account) }
      let(:campaign) { create(:campaign, account: account, inbox: channel.inbox) }

      it 'dispatches to Twilio oneoff service' do
        service = instance_double(Twilio::OneoffSmsCampaignService, perform: true)

        expect(Twilio::OneoffSmsCampaignService).to receive(:new) do |**kwargs|
          service_campaign = kwargs[:campaign]
          run = kwargs[:campaign_run]
          expect(service_campaign).to eq(campaign)
          expect(run).to be_a(CampaignRun)
          service
        end

        runner.perform
      end
    end

    context 'when campaign inbox is Email' do
      let(:account) { create(:account) }
      let(:channel) { create(:channel_email, account: account) }
      let(:campaign) { create(:campaign, account: account, inbox: channel.inbox) }

      it 'dispatches to Email oneoff service' do
        service = instance_double(Email::OneoffCampaignService, perform: true)

        expect(Email::OneoffCampaignService).to receive(:new) do |**kwargs|
          service_campaign = kwargs[:campaign]
          run = kwargs[:campaign_run]
          expect(service_campaign).to eq(campaign)
          expect(run).to be_a(CampaignRun)
          service
        end

        runner.perform
      end
    end

    context 'when campaign inbox is Line' do
      let(:account) { create(:account) }
      let(:channel) { create(:channel_line, account: account, inbox: nil) }
      let(:inbox) { create(:inbox, account: account, channel: channel) }
      let(:campaign) { create(:campaign, account: account, inbox: inbox) }

      it 'dispatches to Line oneoff service' do
        service = instance_double(Line::OneoffCampaignService, perform: true)

        expect(Line::OneoffCampaignService).to receive(:new) do |**kwargs|
          service_campaign = kwargs[:campaign]
          run = kwargs[:campaign_run]
          expect(service_campaign).to eq(campaign)
          expect(run).to be_a(CampaignRun)
          service
        end

        runner.perform
      end
    end

    context 'when campaign inbox is Facebook' do
      let(:account) { create(:account) }
      let(:channel) { create(:channel_facebook_page, account: account, inbox: nil) }
      let(:inbox) { create(:inbox, account: account, channel: channel) }
      let(:campaign) { create(:campaign, account: account, inbox: inbox) }

      before do
        stub_request(:post, /graph.facebook.com/).to_return(status: 200, body: '{}', headers: {})
      end

      it 'dispatches to Facebook oneoff service' do
        service = instance_double(Facebook::OneoffCampaignService, perform: true)

        expect(Facebook::OneoffCampaignService).to receive(:new) do |**kwargs|
          service_campaign = kwargs[:campaign]
          run = kwargs[:campaign_run]
          expect(service_campaign).to eq(campaign)
          expect(run).to be_a(CampaignRun)
          service
        end

        runner.perform
      end
    end

    context 'when campaign inbox is Instagram' do
      let(:account) { create(:account) }
      let(:channel) { create(:channel_instagram, account: account) }
      let(:campaign) { create(:campaign, account: account, inbox: channel.inbox) }

      it 'dispatches to Instagram oneoff service' do
        service = instance_double(Instagram::OneoffCampaignService, perform: true)

        expect(Instagram::OneoffCampaignService).to receive(:new) do |**kwargs|
          service_campaign = kwargs[:campaign]
          run = kwargs[:campaign_run]
          expect(service_campaign).to eq(campaign)
          expect(run).to be_a(CampaignRun)
          service
        end

        runner.perform
      end
    end

    context 'when campaign inbox is Telegram' do
      let(:account) { create(:account) }
      let(:channel) { create(:channel_telegram, account: account) }
      let(:campaign) { create(:campaign, account: account, inbox: channel.inbox) }

      it 'dispatches to Telegram oneoff service' do
        service = instance_double(Telegram::OneoffCampaignService, perform: true)

        expect(Telegram::OneoffCampaignService).to receive(:new) do |**kwargs|
          expect(kwargs[:campaign]).to eq(campaign)
          expect(kwargs[:campaign_run]).to be_a(CampaignRun)
          service
        end

        runner.perform
      end
    end

    context 'when campaign inbox is Tiktok' do
      let(:account) { create(:account) }
      let(:channel) { create(:channel_tiktok, account: account) }
      let(:campaign) { create(:campaign, account: account, inbox: channel.inbox) }

      it 'dispatches to Tiktok oneoff service' do
        service = instance_double(Tiktok::OneoffCampaignService, perform: true)

        expect(Tiktok::OneoffCampaignService).to receive(:new) do |**kwargs|
          expect(kwargs[:campaign]).to eq(campaign)
          expect(kwargs[:campaign_run]).to be_a(CampaignRun)
          service
        end

        runner.perform
      end
    end

    context 'when campaign inbox is Twitter' do
      let(:account) { create(:account) }
      let(:channel) { create(:channel_twitter_profile, account: account) }
      let(:inbox) { create(:inbox, account: account, channel: channel) }
      let(:campaign) { create(:campaign, account: account, inbox: inbox) }

      it 'dispatches to Twitter oneoff service' do
        service = instance_double(Twitter::OneoffCampaignService, perform: true)

        expect(Twitter::OneoffCampaignService).to receive(:new) do |**kwargs|
          expect(kwargs[:campaign]).to eq(campaign)
          expect(kwargs[:campaign_run]).to be_a(CampaignRun)
          service
        end

        runner.perform
      end
    end

    context 'when campaign inbox is unsupported' do
      let(:campaign) { create(:campaign) }

      it 'raises invalid campaign' do
        expect { runner.perform }.to raise_error("Invalid campaign #{campaign.id}")
      end
    end

    context 'when the service raises' do
      let(:account) { create(:account) }
      let(:channel) { create(:channel_sms, account: account) }
      let(:campaign) { create(:campaign, account: account, inbox: channel.inbox) }

      it 'fails the created campaign run' do
        service = instance_double(Sms::OneoffSmsCampaignService)
        expect(service).to receive(:perform).and_raise(StandardError, 'boom')
        expect(Sms::OneoffSmsCampaignService).to receive(:new) { |**| service }

        expect { runner.perform }.to raise_error(StandardError, 'boom')

        run = campaign.campaign_runs.order(:created_at).last
        expect(run).to be_present
        expect(run.failed?).to be(true)
        expect(run.error_message).to eq('boom')
      end
    end

    context 'when retry metadata is provided' do
      let(:account) { create(:account) }
      let(:channel) { create(:channel_email, account: account) }
      let(:campaign) { create(:campaign, account: account, inbox: channel.inbox) }

      it 'passes retry context to the created run and service' do
        source_run = create(:campaign_run, campaign: campaign, account: account, inbox: campaign.inbox)
        service = instance_double(Email::OneoffCampaignService, perform: true)

        expect(Email::OneoffCampaignService).to receive(:new) do |**kwargs|
          service_campaign = kwargs[:campaign]
          run = kwargs[:campaign_run]
          contact_ids = kwargs[:contact_ids]
          allow_terminal_retry = kwargs[:allow_terminal_retry]
          expect(service_campaign).to eq(campaign)
          expect(contact_ids).to eq([11, 22])
          expect(allow_terminal_retry).to be(true)
          expect(run.metadata['retry_source_run_id']).to eq(source_run.id)
          service
        end

        described_class.new(
          campaign: campaign,
          contact_ids: [11, 22],
          retry_source_run: source_run,
          allow_terminal_retry: true
        ).perform
      end
    end

    context 'when restart metadata is provided' do
      let(:account) { create(:account) }
      let(:channel) { create(:channel_email, account: account) }
      let(:campaign) { create(:campaign, account: account, inbox: channel.inbox) }

      it 'marks the created run as restart run' do
        source_run = create(:campaign_run, campaign: campaign, account: account, inbox: campaign.inbox)
        service = instance_double(Email::OneoffCampaignService, perform: true)

        expect(Email::OneoffCampaignService).to receive(:new) { |**| service }

        run = described_class.new(
          campaign: campaign,
          retry_source_run: source_run,
          allow_terminal_retry: true,
          restart_run: true
        ).perform

        expect(run.metadata['retry_source_run_id']).to eq(source_run.id)
        expect(run.metadata['restart_run']).to eq(true)
      end
    end

    context 'when resume metadata is provided' do
      let(:account) { create(:account) }
      let(:channel) { create(:channel_email, account: account) }
      let(:campaign) { create(:campaign, account: account, inbox: channel.inbox) }

      it 'marks the created run as resume run' do
        source_run = create(:campaign_run, campaign: campaign, account: account, inbox: campaign.inbox)
        service = instance_double(Email::OneoffCampaignService, perform: true)

        expect(Email::OneoffCampaignService).to receive(:new) { |**| service }

        run = described_class.new(
          campaign: campaign,
          contact_ids: [12],
          retry_source_run: source_run,
          allow_terminal_retry: true,
          resume_run: true
        ).perform

        expect(run.metadata['retry_source_run_id']).to eq(source_run.id)
        expect(run.metadata['resume_run']).to eq(true)
      end
    end
  end
end
