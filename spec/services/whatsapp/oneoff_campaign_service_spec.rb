require 'rails_helper'

describe Whatsapp::OneoffCampaignService do
  let(:account) { create(:account) }
  let!(:whatsapp_channel) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
  end
  let!(:whatsapp_inbox) { whatsapp_channel.inbox }
  let(:label1) { create(:label, account: account) }
  let(:label2) { create(:label, account: account) }
  let!(:campaign) do
    create(
      :campaign,
      inbox: whatsapp_inbox,
      account: account,
      audience: [{ type: 'Label', id: label1.id }, { type: 'Label', id: label2.id }],
      template_params: template_params
    )
  end
  let(:template_params) do
    {
      'name' => 'ticket_status_updated',
      'namespace' => '23423423_2342423_324234234_2343224',
      'category' => 'UTILITY',
      'language' => 'en',
      'processed_params' => { 'body' => { 'name' => 'John', 'ticket_id' => '2332' } }
    }
  end

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  describe '#perform' do
    before do
      account.enable_features!(:whatsapp_campaign)
    end

    context 'when campaign validation fails' do
      it 'raises error if campaign is completed' do
        campaign.completed!

        expect { described_class.new(campaign: campaign).perform }.to raise_error 'Completed Campaign'
      end

      it 'raises error if campaign has already failed' do
        campaign.failed!

        expect { described_class.new(campaign: campaign).perform }.to raise_error 'Failed Campaign'
      end

      it 'raises error when campaign is not a WhatsApp campaign' do
        sms_channel = create(:channel_sms, account: account)
        sms_inbox = create(:inbox, channel: sms_channel, account: account)
        invalid_campaign = create(:campaign, inbox: sms_inbox, account: account)

        expect { described_class.new(campaign: invalid_campaign).perform }
          .to raise_error "Invalid campaign #{invalid_campaign.id}"
      end

      it 'raises error when campaign is not oneoff' do
        allow(campaign).to receive(:one_off?).and_return(false)

        expect { described_class.new(campaign: campaign).perform }.to raise_error "Invalid campaign #{campaign.id}"
      end

      it 'raises error when channel provider is not whatsapp_cloud' do
        whatsapp_channel.update!(provider: 'default')

        expect { described_class.new(campaign: campaign).perform }.to raise_error 'WhatsApp Cloud provider required'
      end

      it 'raises error when WhatsApp campaigns feature is not enabled' do
        account.disable_features!(:whatsapp_campaign)

        expect { described_class.new(campaign: campaign).perform }.to raise_error 'WhatsApp campaigns feature not enabled'
      end
    end

    context 'when campaign is valid' do
      it 'marks campaign as completed' do
        contact = create(:contact, :with_phone_number, account: account)
        contact.update_labels([label1.title])

        described_class.new(campaign: campaign).perform

        expect(campaign.reload.completed?).to be true
      end

      it 'processes contacts with matching labels through native conversations and messages' do
        contact_with_label1, contact_with_label2, contact_with_both_labels =
          create_list(:contact, 3, :with_phone_number, account: account)
        contact_with_label1.update_labels([label1.title])
        contact_with_label2.update_labels([label2.title])
        contact_with_both_labels.update_labels([label1.title, label2.title])

        described_class.new(campaign: campaign).perform

        expect(campaign.campaign_deliveries.count).to eq(3)
        expect(campaign.campaign_deliveries.pluck(:status).uniq).to eq(['pending'])
        expect(campaign.conversations).to be_empty
        created_conversations = whatsapp_inbox.conversations.where(
          contact: [contact_with_label1, contact_with_label2, contact_with_both_labels]
        )
        expect(created_conversations.count).to eq(3)
        expect(created_conversations.pluck(:status).uniq).to eq(['resolved'])
        expect(created_conversations.pluck(:campaign_id).uniq).to eq([nil])
        expect(created_conversations.all? { |conversation| conversation.messages.outgoing.count == 1 }).to be true
        expect(created_conversations.all? { |conversation| conversation.messages.first.additional_attributes['campaign_id'] == campaign.id }).to be true
        expect(enqueued_jobs.count { |job| job[:job] == SendReplyJob }).to eq(3)
      end

      it 'tags created messages and deliveries with the current campaign run' do
        contact = create(:contact, :with_phone_number, account: account)
        contact.update_labels([label1.title])
        campaign_run = create(:campaign_run, campaign: campaign, account: account, inbox: whatsapp_inbox)

        described_class.new(campaign: campaign, campaign_run: campaign_run).perform

        message = whatsapp_inbox.messages.outgoing.find_by("additional_attributes ->> 'campaign_run_id' = ?", campaign_run.id.to_s)
        delivery = campaign.campaign_deliveries.find_by!(campaign_run: campaign_run, contact: contact)
        expect(message).to be_present
        expect(message.additional_attributes['campaign_id']).to eq(campaign.id)
        expect(delivery.metadata['message_id']).to eq(message.id)
      end

      it 'skips contacts without phone numbers' do
        contact_without_phone = create(:contact, account: account, phone_number: nil)
        contact_without_phone.update_labels([label1.title])

        described_class.new(campaign: campaign).perform

        expect(campaign.campaign_deliveries.find_by(contact: contact_without_phone).status).to eq('skipped')
      end
    end

    context 'when template_params is missing' do
      let(:template_params) { nil }

      it 'skips contacts and logs error' do
        contact = create(:contact, :with_phone_number, account: account)
        contact.update_labels([label1.title])

        expect(Rails.logger).to receive(:error)
          .with("Skipping contact #{contact.name} - no template_params found for WhatsApp campaign")

        described_class.new(campaign: campaign).perform

        expect(campaign.reload.failed?).to be true
        expect(campaign.campaign_deliveries.find_by(contact: contact).status).to eq('skipped')
      end
    end

    context 'when native conversation creation fails for one contact' do
      it 'logs error and continues processing remaining contacts' do
        contact_error, contact_success = create_list(:contact, 2, :with_phone_number, account: account)
        contact_error.update_labels([label1.title])
        contact_success.update_labels([label1.title])
        error_message = 'Builder error'
        expected_campaign = campaign

        builder_error = instance_double(Campaigns::OneoffConversationBuilder)
        builder_success = instance_double(Campaigns::OneoffConversationBuilder)

        allow(Campaigns::OneoffConversationBuilder).to receive(:new) do |campaign:, contact:, campaign_run:|
          expect(campaign).to eq(expected_campaign)
          expect(campaign_run).to be_a(CampaignRun)
          contact == contact_error ? builder_error : builder_success
        end
        expect(builder_error).to receive(:perform).and_raise(StandardError, error_message)
        expect(builder_success).to receive(:perform).and_return(instance_double(Message, id: 123))

        expect(Rails.logger).to receive(:error)
          .with("Failed to create WhatsApp campaign message for #{contact_error.phone_number}: #{error_message}")
        expect(Rails.logger).to receive(:error).with(/Backtrace:/)

        described_class.new(campaign: campaign).perform

        expect(campaign.reload.completed?).to be true
        expect(campaign.campaign_deliveries.find_by(contact: contact_error).status).to eq('failed')
        expect(campaign.campaign_deliveries.find_by(contact: contact_success).status).to eq('pending')
      end
    end
  end
end
