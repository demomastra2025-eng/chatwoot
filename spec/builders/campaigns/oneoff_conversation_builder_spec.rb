require 'rails_helper'

describe Campaigns::OneoffConversationBuilder do
  subject(:builder) { described_class.new(campaign: campaign, contact: contact) }

  let(:account) { create(:account) }
  let(:whatsapp_channel) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
  end
  let(:inbox) { whatsapp_channel.inbox }
  let(:contact) { create(:contact, :with_phone_number, account: account) }
  let(:campaign) do
    create(
      :campaign,
      inbox: inbox,
      account: account,
      template_params: {
        'name' => 'ticket_status_updated',
        'language' => 'en',
        'category' => 'UTILITY',
        'processed_params' => { 'body' => { 'first_name' => 'John' } }
      }
    )
  end

  describe '#perform' do
    it 'creates a resolved conversation and native campaign message' do
      message = builder.perform

      expect(message.conversation.campaign_id).to eq(campaign.id)
      expect(message.conversation).to be_resolved
      expect(message.conversation.waiting_since).to be_nil
      expect(message.additional_attributes['campaign_id']).to eq(campaign.id)
      expect(message.additional_attributes['template_params']).to eq(campaign.template_params)
      expect(message.conversation.contact_inbox.source_id).to eq(contact.phone_number.delete('+'))
    end

    it 'reuses the same conversation and message on repeated runs' do
      first_message = builder.perform
      second_message = builder.perform

      expect(second_message.id).to eq(first_message.id)
      expect(Conversation.where(campaign: campaign, contact: contact).count).to eq(1)
      expect(first_message.conversation.messages.count).to eq(1)
    end

    it 'reuses an existing contact inbox for the contact' do
      existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '77001234567')

      message = builder.perform

      expect(message.conversation.contact_inbox_id).to eq(existing_contact_inbox.id)
    end
  end
end
