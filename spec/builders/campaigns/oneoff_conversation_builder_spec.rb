require 'rails_helper'

describe Campaigns::OneoffConversationBuilder do
  describe '#perform' do
    let(:account) { create(:account) }
    let(:contact) { create(:contact, :with_phone_number, account: account) }

    context 'for single-conversation inboxes' do
      subject(:builder) { described_class.new(campaign: campaign, contact: contact) }

      let(:whatsapp_channel) do
        create(
          :channel_whatsapp,
          account: account,
          provider: 'whatsapp_cloud',
          validate_provider_config: false,
          sync_templates: false
        )
      end
      let(:inbox) { whatsapp_channel.inbox }
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
      let(:campaign_run) { create(:campaign_run, campaign: campaign, account: account, inbox: inbox, status: :running) }

      it 'creates a resolved conversation and keeps campaign tracking on the message' do
        message = builder.perform

        expect(message.conversation.campaign_id).to be_nil
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
        expect(Conversation.where(contact: contact, inbox: inbox).count).to eq(1)
        expect(first_message.conversation.messages.count).to eq(1)
      end

      it 'creates a new campaign message for a different campaign run in the same conversation' do
        first_message = described_class.new(
          campaign: campaign,
          campaign_run: campaign_run,
          contact: contact
        ).perform
        second_run = create(:campaign_run, campaign: campaign, account: account, inbox: inbox, status: :running)

        second_message = described_class.new(
          campaign: campaign,
          campaign_run: second_run,
          contact: contact
        ).perform

        expect(second_message.id).not_to eq(first_message.id)
        expect(second_message.additional_attributes['campaign_run_id']).to eq(second_run.id)
        expect(first_message.conversation_id).to eq(second_message.conversation_id)
      end

      it 'reuses an existing contact inbox for the contact' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '77001234567')

        message = builder.perform

        expect(message.conversation.contact_inbox_id).to eq(existing_contact_inbox.id)
      end

      it 'reuses the latest non-campaign conversation instead of creating a new campaign thread' do
        existing_contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox, source_id: '77001234567')
        original_conversation = create(
          :conversation,
          account: account,
          inbox: inbox,
          contact: contact,
          contact_inbox: existing_contact_inbox
        )
        create(
          :conversation,
          account: account,
          inbox: inbox,
          contact: contact,
          contact_inbox: existing_contact_inbox,
          campaign: create(:campaign, inbox: inbox, account: account),
          status: :resolved
        )

        message = builder.perform

        expect(message.conversation_id).to eq(original_conversation.id)
        expect(Conversation.where(contact: contact, inbox: inbox).count).to eq(2)
      end

      it 'creates a contact inbox with the provided source id when one does not exist' do
        whatsapp_web_channel = create(:channel_whatsapp_web, account: account)
        whatsapp_web_inbox = whatsapp_web_channel.inbox
        whatsapp_web_campaign = create(:campaign, inbox: whatsapp_web_inbox, account: account)

        message = described_class.new(
          campaign: whatsapp_web_campaign,
          contact: contact,
          source_id: '15550001111'
        ).perform

        expect(message.conversation.contact_inbox.source_id).to eq('15550001111')
        expect(message.conversation.campaign_id).to be_nil
      end

      it 'merges custom conversation attributes into the reused single conversation' do
        telegram_channel = create(:channel_telegram, account: account)
        telegram_campaign = create(:campaign, inbox: telegram_channel.inbox, account: account)
        telegram_contact = create(:contact, account: account, additional_attributes: { 'social_telegram_user_id' => '7788' })
        telegram_contact_inbox = create(
          :contact_inbox,
          inbox: telegram_channel.inbox,
          contact: telegram_contact,
          source_id: '7788'
        )
        existing_conversation = create(
          :conversation,
          account: account,
          inbox: telegram_channel.inbox,
          contact: telegram_contact,
          contact_inbox: telegram_contact_inbox,
          additional_attributes: { chat_id: '7788' }
        )

        message = described_class.new(
          campaign: telegram_campaign,
          contact: telegram_contact,
          source_id: '7788',
          conversation_attributes: { business_connection_id: 'biz-1' }
        ).perform

        expect(message.conversation_id).to eq(existing_conversation.id)
        expect(message.conversation.campaign_id).to be_nil
        expect(message.conversation.additional_attributes['chat_id']).to eq('7788')
        expect(message.conversation.additional_attributes['business_connection_id']).to eq('biz-1')
      end
    end

    context 'for multi-conversation inboxes' do
      let(:email_channel) { create(:channel_email, account: account) }
      let(:email_contact) { create(:contact, account: account, email: 'buyer@example.com') }
      let(:campaign) do
        create(
          :campaign,
          inbox: email_channel.inbox,
          account: account,
          title: 'April Promotion'
        )
      end

      it 'creates a dedicated campaign conversation with the campaign attached' do
        message = described_class.new(
          campaign: campaign,
          contact: email_contact,
          source_id: email_contact.email
        ).perform

        expect(message.conversation.campaign_id).to eq(campaign.id)
        expect(message.conversation.additional_attributes['mail_subject']).to eq('April Promotion')
        expect(message.conversation.contact_inbox.source_id).to eq('buyer@example.com')
      end

      it 'generates message content with the AI agent when the campaign uses agent mode' do
        create(
          :captain_inbox,
          inbox: email_channel.inbox,
          captain_assistant: create(:captain_assistant, account: account)
        )
        campaign.update!(message: '', instructions: 'Write a short follow-up', text_mode: :agent)
        generator = instance_double(
          Campaigns::CaptainGeneratedMessageService,
          perform: { content: 'Hello from AI' }
        )

        allow(Campaigns::CaptainGeneratedMessageService).to receive(:new).and_return(generator)

        message = described_class.new(
          campaign: campaign,
          contact: email_contact,
          source_id: email_contact.email
        ).perform

        expect(message.content).to eq('Hello from AI')
        expect(Campaigns::CaptainGeneratedMessageService).to have_received(:new).with(
          campaign: campaign,
          conversation: message.conversation
        )
      end
    end
  end
end
