# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Campaign do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:inbox) }
    it { is_expected.to have_many(:campaign_deliveries).dependent(:delete_all) }
    it { is_expected.to have_many(:campaign_runs).dependent(:delete_all) }
  end

  describe '.before_create' do
    let(:account) { create(:account) }
    let(:website_channel) { create(:channel_widget, account: account) }
    let(:website_inbox) { create(:inbox, channel: website_channel, account: account) }
    let(:campaign) { build(:campaign, account: account, inbox: website_inbox, display_id: nil, trigger_rules: { url: 'https://test.com' }) }

    before do
      campaign.save!
      campaign.reload
    end

    it 'runs before_create callbacks' do
      expect(campaign.display_id).to eq(1)
    end
  end

  context 'when inbox type is unsupported for campaigns' do
    let(:account) { create(:account, limits: { non_web_inboxes: 10 }) }
    let(:api_channel) { build(:channel_api, account: account) }
    let(:api_inbox) { create(:inbox, channel: api_channel, account: account) }
    let(:campaign) { build(:campaign, inbox: api_inbox, account: account) }

    it 'would not save the campaigns' do
      expect(campaign.save).to be false
      expect(campaign.errors.full_messages.first).to eq 'Inbox Unsupported Inbox type'
    end
  end

  context 'when a campaign is completed' do
    let(:account) { create(:account) }
    let(:web_widget) { create(:channel_widget, account: account) }
    let!(:campaign) { create(:campaign, account: account, inbox: web_widget.inbox, campaign_status: :completed, trigger_rules: { url: 'https://test.com' }) }

    it 'would prevent further updates' do
      campaign.title = 'new name'
      expect(campaign.save).to be false
      expect(campaign.errors.full_messages.first).to eq 'Status The campaign can no longer be updated'
    end

    it 'can be deleted' do
      campaign.destroy!
      expect(described_class.exists?(campaign.id)).to be false
    end

    it 'cant be triggered' do
      expect(Campaigns::OneoffRunner).not_to receive(:new).with(campaign: campaign)
      expect(campaign.trigger!).to be_nil
    end
  end

  context 'when a campaign is already running' do
    let(:account) { create(:account) }
    let(:sms_channel) { create(:channel_sms, account: account) }
    let(:sms_inbox) { create(:inbox, channel: sms_channel, account: account) }
    let!(:campaign) { create(:campaign, account: account, inbox: sms_inbox, campaign_status: :running) }

    it 'does not trigger again' do
      expect(Campaigns::OneoffRunner).not_to receive(:new).with(campaign: campaign)
      expect(campaign.trigger!).to be_nil
    end
  end

  context 'when cancelling a one-off campaign' do
    let(:account) { create(:account) }
    let(:email_channel) { create(:channel_email, account: account) }
    let(:email_inbox) { create(:inbox, channel: email_channel, account: account) }
    let!(:campaign) { create(:campaign, account: account, inbox: email_inbox, campaign_status: :active) }

    it 'marks an active one-off campaign as cancelled' do
      campaign.cancel_one_off!

      expect(campaign.reload.cancelled?).to be(true)
    end

    it 'raises when trying to cancel a terminal campaign' do
      campaign.update_column(:campaign_status, Campaign.campaign_statuses[:completed])

      expect { campaign.cancel_one_off! }.to raise_error(ActiveRecord::RecordInvalid)
      expect(campaign.reload.completed?).to be(true)
    end
  end

  context 'when cancelling a running one-off campaign' do
    let(:account) { create(:account) }
    let(:email_channel) { create(:channel_email, account: account) }
    let(:email_inbox) { create(:inbox, channel: email_channel, account: account) }
    let!(:campaign) { create(:campaign, account: account, inbox: email_inbox, campaign_status: :running) }
    let!(:run) { create(:campaign_run, campaign: campaign, account: account, inbox: email_inbox, status: :running) }

    it 'cancels the campaign and its latest running run' do
      campaign.cancel_one_off!

      expect(campaign.reload.cancelled?).to be(true)
      expect(run.reload.cancelled?).to be(true)
    end
  end

  context 'when a campaign has deliveries' do
    let(:campaign) { create(:campaign) }

    it 'can be deleted without foreign key violations' do
      delivery = create(:campaign_delivery, campaign: campaign, account: campaign.account, inbox: campaign.inbox)

      campaign.destroy!

      expect(described_class.exists?(campaign.id)).to be false
      expect(CampaignDelivery.exists?(delivery.id)).to be false
    end
  end

  describe 'official WhatsApp delivery policy' do
    let(:account) { create(:account) }
    let(:label) { create(:label, account: account, title: 'vip') }
    let(:audience) { [{ type: 'Label', id: label.id }] }

    before do
      account.enable_features!(:whatsapp_campaign)
    end

    it 'rejects free-text one-off campaigns that will deliver after the 24-hour window closes' do
      channel = create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
      inbox = channel.inbox
      contact = create(:contact, account: account, phone_number: '+15550001116')
      contact.update_labels([label.title])
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox)
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
      create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, created_at: 1.hour.ago)

      campaign = build(:campaign, account: account, inbox: inbox, audience: audience, scheduled_at: 25.hours.from_now, message: 'Future free text')

      expect(campaign).not_to be_valid
      expect(campaign.errors[:base]).to include(Outbound::DeliveryPolicy::WHATSAPP_TEMPLATE_REQUIRED_REASON)
    end
  end

  describe 'ensure_correct_campaign_attributes' do
    context 'when Twilio SMS campaign' do
      let(:account) { create(:account) }
      let!(:twilio_sms) { create(:channel_twilio_sms, account: account) }
      let!(:twilio_inbox) { create(:inbox, channel: twilio_sms, account: account) }
      let(:campaign) { build(:campaign, account: account, inbox: twilio_inbox) }

      it 'only saves campaign type as oneoff and wont leave scheduled_at empty' do
        campaign.campaign_type = 'ongoing'
        campaign.save!
        expect(campaign.reload.campaign_type).to eq 'one_off'
        expect(campaign.scheduled_at.present?).to be true
      end

      it 'calls twilio service on trigger!' do
        runner = double
        expect(Campaigns::OneoffRunner).to receive(:new).with(campaign: campaign).and_return(runner)
        expect(runner).to receive(:perform)
        campaign.save!
        campaign.trigger!
      end

      it 'marks the campaign as failed when the runner raises' do
        runner = double
        expect(Campaigns::OneoffRunner).to receive(:new).with(campaign: campaign).and_return(runner)
        expect(runner).to receive(:perform).and_raise(StandardError, 'boom')

        campaign.save!

        expect { campaign.trigger! }.to raise_error(StandardError, 'boom')
        expect(campaign.reload.failed?).to be(true)
      end

      it 'marks the campaign as running before delegating to the runner' do
        runner = double
        expect(Campaigns::OneoffRunner).to receive(:new).with(campaign: campaign).and_return(runner)
        expect(runner).to receive(:perform) do
          expect(campaign.reload.running?).to be(true)
        end

        campaign.save!
        campaign.trigger!
      end
    end

    context 'when SMS campaign' do
      let(:account) { create(:account) }
      let!(:sms_channel) { create(:channel_sms, account: account) }
      let!(:sms_inbox) { create(:inbox, channel: sms_channel, account: account) }
      let(:campaign) { build(:campaign, account: account, inbox: sms_inbox) }

      it 'only saves campaign type as oneoff and wont leave scheduled_at empty' do
        campaign.campaign_type = 'ongoing'
        campaign.save!
        expect(campaign.reload.campaign_type).to eq 'one_off'
        expect(campaign.scheduled_at.present?).to be true
      end

      it 'calls sms service on trigger!' do
        runner = double
        expect(Campaigns::OneoffRunner).to receive(:new).with(campaign: campaign).and_return(runner)
        expect(runner).to receive(:perform)
        campaign.save!
        campaign.trigger!
      end
    end

    context 'when Email campaign' do
      let(:account) { create(:account) }
      let!(:email_channel) { create(:channel_email, account: account) }
      let!(:email_inbox) { create(:inbox, channel: email_channel, account: account) }
      let(:label) { create(:label, account: account, title: 'vip') }
      let(:campaign) { create(:campaign, account: account, inbox: email_inbox, audience: [{ type: 'Label', id: label.id }]) }

      before do
        create(:contact, account: account, email: 'vip@example.com').update_labels([label.title])
      end

      it 'executes successfully through the trigger path' do
        expect { campaign.trigger! }.not_to raise_error

        expect(campaign.reload.completed?).to be(true)
        expect(campaign.campaign_runs.count).to eq(1)
        expect(campaign.campaign_runs.last.completed?).to be(true)
      end
    end

    context 'when Website campaign' do
      let(:campaign) { build(:campaign) }

      it 'only saves campaign type as ongoing' do
        campaign.campaign_type = 'one_off'
        campaign.save!
        expect(campaign.reload.campaign_type).to eq 'ongoing'
      end
    end
  end

  context 'when validating sender' do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:web_widget) { create(:channel_widget, account: account) }
    let(:inbox) { create(:inbox, channel: web_widget, account: account) }

    it 'allows sender from the same account' do
      campaign = build(:campaign, inbox: inbox, account: account, sender: user)
      expect(campaign).to be_valid
    end

    it 'does not allow sender from different account' do
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      campaign = build(:campaign, inbox: inbox, account: account, sender: other_user)
      expect(campaign).not_to be_valid
      expect(campaign.errors[:sender_id]).to include(
        'must belong to the same account as the campaign'
      )
    end
  end

  context 'when validating inbox' do
    let(:account) { create(:account) }
    let(:other_account) { create(:account) }
    let(:web_widget) { create(:channel_widget, account: account) }
    let(:inbox) { create(:inbox, channel: web_widget, account: account) }
    let(:other_account_inbox) { create(:inbox, account: other_account) }

    it 'allows inbox from the same account' do
      campaign = build(:campaign, inbox: inbox, account: account)
      expect(campaign).to be_valid
    end

    it 'does not allow inbox from different account' do
      campaign = build(:campaign, inbox: other_account_inbox, account: account)
      expect(campaign).not_to be_valid
      expect(campaign.errors[:inbox_id]).to include(
        'must belong to the same account as the campaign'
      )
    end
  end
end
