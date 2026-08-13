require 'rails_helper'

RSpec.describe Campaigns::AnalyticsService do
  subject(:service) { described_class.new(campaign: campaign) }

  let(:account) { create(:account) }
  let(:sms_channel) { create(:channel_sms, account: account) }
  let(:sms_inbox) { create(:inbox, channel: sms_channel, account: account) }
  let(:label) { create(:label, account: account, title: 'vip') }
  let!(:campaign) do
    create(
      :campaign,
      account: account,
      inbox: sms_inbox,
      audience: [{ type: 'Label', id: label.id }]
    )
  end

  describe '#call' do
    it 'returns audience and not sent metrics independently from deliveries' do
      contact_with_delivery = create(:contact, :with_phone_number, account: account)
      contact_without_delivery = create(:contact, :with_phone_number, account: account)
      campaign_run = create(
        :campaign_run,
        campaign: campaign,
        account: account,
        inbox: sms_inbox,
        status: :completed,
        total_count: 2,
        processed_count: 1,
        successful_count: 1
      )
      contact_with_delivery.update_labels([label.title])
      contact_without_delivery.update_labels([label.title])

      create(
        :campaign_delivery,
        campaign: campaign,
        campaign_run: campaign_run,
        account: account,
        inbox: sms_inbox,
        contact: contact_with_delivery,
        status: :submitted
      )

      result = service.call

      expect(result[:campaign_status]).to eq(campaign.campaign_status)
      expect(result[:audience_size]).to eq(2)
      expect(result[:deliveries_count]).to eq(1)
      expect(result[:delivery_attempts_count]).to eq(1)
      expect(result[:not_sent_count]).to eq(1)
      expect(result[:coverage_rate]).to eq(50.0)
      expect(result[:latest_run][:id]).to eq(campaign_run.id)
      expect(result[:latest_run][:status]).to eq('completed')
      expect(result[:latest_run][:provider]).to be_nil
      expect(result[:not_sent_contacts].pluck(:id)).to eq([contact_without_delivery.id])
    end

    it 'retains deleted imported recipients in audience and skipped coverage totals' do
      contact = create(:contact, account: account, phone_number: '+77051234567')
      audience_import = create(:campaign_audience_import, account: account, inbox: sms_inbox)
      create(
        :campaign_audience_recipient,
        campaign_audience_import: audience_import,
        account: account,
        contact: contact,
        normalized_phone_number: contact.phone_number
      )
      campaign.update!(audience: [], campaign_audience_import: audience_import)
      contact.destroy!

      result = service.call

      expect(result[:audience_size]).to eq(1)
      expect(result[:processed_contacts_count]).to eq(1)
      expect(result[:coverage_rate]).to eq(100.0)
      expect(result[:totals]['skipped']).to eq(1)
    end

    it 'returns full coverage when all audience contacts have deliveries' do
      contact_1 = create(:contact, :with_phone_number, account: account)
      contact_2 = create(:contact, :with_phone_number, account: account)
      contact_1.update_labels([label.title])
      contact_2.update_labels([label.title])

      create(:campaign_delivery, campaign: campaign, account: account, inbox: sms_inbox, contact: contact_1, status: :delivered)
      create(:campaign_delivery, campaign: campaign, account: account, inbox: sms_inbox, contact: contact_2, status: :read)

      result = service.call

      expect(result[:audience_size]).to eq(2)
      expect(result[:deliveries_count]).to eq(2)
      expect(result[:delivery_attempts_count]).to eq(2)
      expect(result[:not_sent_count]).to eq(0)
      expect(result[:coverage_rate]).to eq(100.0)
      expect(result[:success_rate]).to eq(100.0)
    end

    it 'falls back to delivered contacts when the campaign has no explicit audience' do
      campaign.update!(audience: [])
      contact_1 = create(:contact, :with_phone_number, account: account)
      contact_2 = create(:contact, :with_phone_number, account: account)

      create(
        :campaign_delivery,
        campaign: campaign,
        account: account,
        inbox: sms_inbox,
        contact: contact_1,
        status: :delivered
      )
      create(
        :campaign_delivery,
        campaign: campaign,
        account: account,
        inbox: sms_inbox,
        contact: contact_2,
        status: :failed
      )

      result = service.call

      expect(result[:audience_size]).to eq(2)
      expect(result[:deliveries_count]).to eq(2)
      expect(result[:not_sent_count]).to eq(0)
      expect(result[:coverage_rate]).to eq(100.0)
    end

    it 'keeps processed coverage at the contact level after retries' do
      contact = create(:contact, :with_phone_number, account: account)
      contact.update_labels([label.title])

      first_run = create(
        :campaign_run,
        campaign: campaign,
        account: account,
        inbox: sms_inbox,
        status: :failed
      )
      second_run = create(
        :campaign_run,
        campaign: campaign,
        account: account,
        inbox: sms_inbox,
        status: :completed
      )

      create(
        :campaign_delivery,
        campaign: campaign,
        campaign_run: first_run,
        account: account,
        inbox: sms_inbox,
        contact: contact,
        status: :failed
      )
      create(
        :campaign_delivery,
        campaign: campaign,
        campaign_run: second_run,
        account: account,
        inbox: sms_inbox,
        contact: contact,
        status: :delivered
      )

      result = service.call

      expect(result[:audience_size]).to eq(1)
      expect(result[:deliveries_count]).to eq(1)
      expect(result[:delivery_attempts_count]).to eq(2)
      expect(result[:not_sent_count]).to eq(0)
      expect(result[:coverage_rate]).to eq(100.0)
    end

    it 'serializes recent runs with retry and duration metadata' do
      older_run = create(
        :campaign_run,
        campaign: campaign,
        account: account,
        inbox: sms_inbox,
        status: :failed,
        created_at: 2.hours.ago,
        started_at: 2.hours.ago,
        completed_at: 110.minutes.ago,
        total_count: 10,
        processed_count: 10,
        successful_count: 3,
        failed_count: 5,
        skipped_count: 2,
        metadata: {
          provider: 'sms',
          inbox_type: sms_inbox.inbox_type
        }
      )

      retried_run = create(
        :campaign_run,
        campaign: campaign,
        account: account,
        inbox: sms_inbox,
        status: :completed,
        created_at: 1.hour.ago,
        started_at: 1.hour.ago,
        completed_at: 50.minutes.ago,
        total_count: 5,
        processed_count: 5,
        successful_count: 5,
        failed_count: 0,
        skipped_count: 0,
        metadata: {
          provider: 'sms',
          inbox_type: sms_inbox.inbox_type,
          retry_source_run_id: older_run.id,
          retry_contacts_count: 5
        }
      )

      result = service.call

      expect(result[:latest_run][:id]).to eq(retried_run.id)
      expect(result[:latest_run][:retry_source_run_id]).to eq(older_run.id)
      expect(result[:latest_run][:retry_contacts_count]).to eq(5)
      expect(result[:latest_run][:duration_seconds]).to eq(600)
      expect(result[:recent_runs].first[:id]).to eq(retried_run.id)
      expect(result[:recent_runs].second[:id]).to eq(older_run.id)
    end

    it 'returns up-to-date latest run counters after provider delivery updates' do
      campaign_run = create(
        :campaign_run,
        campaign: campaign,
        account: account,
        inbox: sms_inbox,
        status: :completed,
        total_count: 1
      )
      delivery = create(
        :campaign_delivery,
        campaign: campaign,
        campaign_run: campaign_run,
        account: account,
        inbox: sms_inbox,
        status: :submitted
      )

      delivery.mark_status!(status: :delivered)

      result = service.call

      expect(result[:latest_run][:id]).to eq(campaign_run.id)
      expect(result[:latest_run][:successful_count]).to eq(1)
      expect(result[:latest_run][:failed_count]).to eq(0)
    end
  end
end
