require 'rails_helper'

describe Sms::OneoffSmsCampaignService do
  subject(:sms_campaign_service) { described_class.new(campaign: campaign) }

  let(:account) { create(:account) }
  let!(:sms_channel) { create(:channel_sms, account: account) }
  let!(:sms_inbox) { create(:inbox, channel: sms_channel, account: account) }
  let(:label1) { create(:label, account: account) }
  let(:label2) { create(:label, account: account) }
  let!(:campaign) do
    create(:campaign, inbox: sms_inbox, account: account,
                      audience: [{ type: 'Label', id: label1.id }, { type: 'Label', id: label2.id }])
  end

  describe 'perform' do
    before do
      stub_request(:post, 'https://messaging.bandwidth.com/api/v2/users/1/messages').to_return(
        status: 200,
        body: { 'id' => '1' }.to_json,
        headers: {}
      )
      allow_any_instance_of(described_class).to receive(:channel).and_return(sms_channel) # rubocop:disable RSpec/AnyInstance
    end

    it 'raises error if the campaign is completed' do
      campaign.completed!

      expect { sms_campaign_service.perform }.to raise_error 'Completed Campaign'
    end

    it 'raises error if the campaign has already failed' do
      campaign.failed!

      expect { sms_campaign_service.perform }.to raise_error 'Failed Campaign'
    end

    it 'raises error invalid campaign when its not a oneoff sms campaign' do
      campaign = create(:campaign)

      expect { described_class.new(campaign: campaign).perform }.to raise_error "Invalid campaign #{campaign.id}"
    end

    it 'send messages to contacts in the audience and marks the campaign completed' do
      contact_with_label1, contact_with_label2, contact_with_both_labels = FactoryBot.create_list(:contact, 3, :with_phone_number, account: account)
      contact_with_label1.update_labels([label1.title])
      contact_with_label2.update_labels([label2.title])
      contact_with_both_labels.update_labels([label1.title, label2.title])
      sms_campaign_service.perform
      assert_requested(:post, 'https://messaging.bandwidth.com/api/v2/users/1/messages', times: 3)
      expect(campaign.reload.completed?).to be true
      expect(campaign.campaign_deliveries.count).to eq(3)
      expect(campaign.campaign_deliveries.pluck(:status).uniq).to eq(['submitted'])
    end

    it 'uses liquid template service to process campaign message' do
      contact = create(:contact, :with_phone_number, account: account)
      contact.update_labels([label1.title])

      expect(Liquid::CampaignTemplateService).to receive(:new).with(campaign: campaign, contact: contact).and_call_original

      sms_campaign_service.perform
    end

    it 'delivers to the immutable imported phone snapshot when the contact phone changes later' do
      imported_phone_number = '+77051234567'
      contact = create(:contact, account: account, phone_number: imported_phone_number)
      audience_import = create(:campaign_audience_import, account: account, inbox: sms_inbox)
      create(
        :campaign_audience_recipient,
        campaign_audience_import: audience_import,
        account: account,
        contact: contact,
        normalized_phone_number: imported_phone_number
      )
      campaign.update!(audience: [], campaign_audience_import: audience_import)
      contact.update!(phone_number: '+77051234568')

      expect(sms_channel).to receive(:send_text_message).with(imported_phone_number, anything).and_return('sms-message-id')

      sms_campaign_service.perform

      expect(campaign.campaign_deliveries.find_by!(contact: contact).target_identifier).to eq(imported_phone_number)
    end

    it 'counts a deleted imported recipient as skipped without sending to its snapshot number' do
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

      expect(sms_channel).not_to receive(:send_text_message)

      sms_campaign_service.perform

      run = campaign.campaign_runs.order(:id).last
      expect(run.attributes).to include('total_count' => 1, 'processed_count' => 1, 'skipped_count' => 1, 'successful_count' => 0)
      expect(campaign.reload).to be_failed
    end

    it 'marks the campaign as failed when no contact can be delivered' do
      contact_without_phone = create(:contact, account: account, phone_number: nil)
      contact_without_phone.update_labels([label1.title])

      sms_campaign_service.perform

      expect(campaign.reload.failed?).to be(true)
      expect(campaign.campaign_deliveries.find_by(contact: contact_without_phone).status).to eq('skipped')
    end

    it 'continues processing contacts when sending message raises an error' do
      contact_error, contact_success = FactoryBot.create_list(:contact, 2, :with_phone_number, account: account)
      contact_error.update_labels([label1.title])
      contact_success.update_labels([label1.title])

      error_message = 'SMS provider error'

      expect(sms_channel).to receive(:send_text_message).with(contact_error.phone_number, anything).and_raise(StandardError, error_message)
      expect(sms_channel).to receive(:send_text_message).with(contact_success.phone_number, anything).and_return('sms-message-id')

      expect(Rails.logger).to receive(:error).with(
        "[SMS Campaign #{campaign.id}] Delivery failed for contact=#{contact_error.id}: StandardError"
      )

      sms_campaign_service.perform
      expect(campaign.reload.completed?).to be true
      expect(campaign.campaign_deliveries.find_by(contact: contact_error).status).to eq('failed')
      expect(campaign.campaign_deliveries.find_by(contact: contact_success).status).to eq('submitted')
    end
  end
end
