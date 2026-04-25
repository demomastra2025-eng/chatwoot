require 'rails_helper'

describe Whatsapp::IncomingMessageWhatsappCloudService do
  describe '#perform' do
    after do
      Redis::Alfred.scan_each(match: 'MESSAGE_SOURCE_KEY::*') { |key| Redis::Alfred.delete(key) }
    end

    let!(:whatsapp_channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }
    let(:params) do
      {
        phone_number: whatsapp_channel.phone_number,
        object: 'whatsapp_business_account',
        entry: [{
          changes: [{
            value: {
              contacts: [{ profile: { name: 'Sojan Jose' }, wa_id: '2423423243' }],
              messages: [{
                from: '2423423243',
                image: {
                  id: 'b1c68f38-8734-4ad3-b4a1-ef0c10d683',
                  mime_type: 'image/jpeg',
                  sha256: '29ed500fa64eb55fc19dc4124acb300e5dcca0f822a301ae99944db',
                  caption: 'Check out my product!'
                },
                timestamp: '1664799904', type: 'image'
              }]
            }
          }]
        }]
      }.with_indifferent_access
    end

    context 'when valid attachment message params' do
      it 'creates appropriate conversations, message and contacts' do
        stub_media_url_request
        stub_sample_png_request
        described_class.new(inbox: whatsapp_channel.inbox, params: params).perform
        expect_conversation_created
        expect_contact_name
        expect_message_content
        expect_message_has_attachment
      end

      it 'increments reauthorization count if fetching attachment fails' do
        stub_request(
          :get,
          whatsapp_channel.media_url('b1c68f38-8734-4ad3-b4a1-ef0c10d683')
        ).to_return(
          status: 401
        )

        described_class.new(inbox: whatsapp_channel.inbox, params: params).perform
        expect(whatsapp_channel.inbox.conversations.count).not_to eq(0)
        expect(Contact.all.first.name).to eq('Sojan Jose')
        expect(whatsapp_channel.inbox.messages.first.content).to eq('Check out my product!')
        expect(whatsapp_channel.inbox.messages.first.attachments.present?).to be false
        expect(whatsapp_channel.authorization_error_count).to eq(1)
      end
    end

    context 'when invalid attachment message params' do
      let(:error_params) do
        {
          phone_number: whatsapp_channel.phone_number,
          object: 'whatsapp_business_account',
          entry: [{
            changes: [{
              value: {
                contacts: [{ profile: { name: 'Sojan Jose' }, wa_id: '2423423243' }],
                messages: [{
                  from: '2423423243',
                  image: {
                    id: 'b1c68f38-8734-4ad3-b4a1-ef0c10d683',
                    mime_type: 'image/jpeg',
                    sha256: '29ed500fa64eb55fc19dc4124acb300e5dcca0f822a301ae99944db',
                    caption: 'Check out my product!'
                  },
                  errors: [{
                    code: 400,
                    details: 'Last error was: ServerThrottle. Http request error: HTTP response code said error. See logs for details',
                    title: 'Media download failed: Not retrying as download is not retriable at this time'
                  }],
                  timestamp: '1664799904', type: 'image'
                }]
              }
            }]
          }]
        }.with_indifferent_access
      end

      it 'with attachment errors' do
        described_class.new(inbox: whatsapp_channel.inbox, params: error_params).perform
        expect(whatsapp_channel.inbox.conversations.count).not_to eq(0)
        expect(Contact.all.first.name).to eq('Sojan Jose')
        expect(whatsapp_channel.inbox.messages.count).to eq(0)
      end
    end

    context 'when invalid params' do
      it 'will not throw error' do
        described_class.new(inbox: whatsapp_channel.inbox, params: { phone_number: whatsapp_channel.phone_number,
                                                                     object: 'whatsapp_business_account', entry: {} }).perform
        expect(whatsapp_channel.inbox.conversations.count).to eq(0)
        expect(Contact.all.first).to be_nil
        expect(whatsapp_channel.inbox.messages.count).to eq(0)
      end
    end

    context 'when message is a reply (has context)' do
      let(:reply_params) do
        {
          phone_number: whatsapp_channel.phone_number,
          object: 'whatsapp_business_account',
          entry: [{
            changes: [{
              value: {
                contacts: [{ profile: { name: 'Pranav' }, wa_id: '16503071063' }],
                messages: [{
                  context: {
                    from: '16503071063',
                    id: 'wamid.ORIGINAL_MESSAGE_ID'
                  },
                  from: '16503071063',
                  id: 'wamid.REPLY_MESSAGE_ID',
                  timestamp: '1770407829',
                  text: { body: 'This is a reply' },
                  type: 'text'
                }]
              }
            }]
          }]
        }.with_indifferent_access
      end

      context 'when the original message exists in Chatwoot' do
        it 'reuses the original campaign conversation and sets in_reply_to' do
          contact = create(:contact, phone_number: '+16503071063', account: whatsapp_channel.account)
          contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_channel.inbox, source_id: '16503071063')
          campaign = create(
            :campaign,
            account: whatsapp_channel.account,
            inbox: whatsapp_channel.inbox,
            template_params: {
              'name' => 'ticket_status_updated',
              'language' => 'en_US',
              'category' => 'UTILITY',
              'processed_params' => { 'body' => { 'name' => 'John' } }
            }
          )
          conversation = create(
            :conversation,
            status: :resolved,
            campaign: campaign,
            contact: contact,
            inbox: whatsapp_channel.inbox,
            contact_inbox: contact_inbox
          )

          original_message = create(:message,
                                    conversation: conversation,
                                    message_type: :outgoing,
                                    additional_attributes: { campaign_id: campaign.id },
                                    source_id: 'wamid.ORIGINAL_MESSAGE_ID',
                                    content: 'Original message')

          described_class.new(inbox: whatsapp_channel.inbox, params: reply_params).perform

          reply_message = whatsapp_channel.inbox.messages.last
          expect(reply_message.content).to eq('This is a reply')
          expect(reply_message.conversation_id).to eq(conversation.id)
          expect(reply_message.content_attributes['in_reply_to']).to eq(original_message.id)
          expect(reply_message.content_attributes['in_reply_to_external_id']).to eq('wamid.ORIGINAL_MESSAGE_ID')
          expect(conversation.reload).to be_open
        end
      end

      context 'when the original message does not exist in Chatwoot' do
        it 'does not set in_reply_to (discards the reply reference)' do
          described_class.new(inbox: whatsapp_channel.inbox, params: reply_params).perform

          reply_message = whatsapp_channel.inbox.messages.last
          expect(reply_message.content).to eq('This is a reply')
          expect(reply_message.content_attributes['in_reply_to']).to be_nil
          expect(reply_message.content_attributes['in_reply_to_external_id']).to be_nil
        end
      end
    end

    context 'when the latest conversation is a resolved campaign conversation without reply context' do
      let(:campaign_reply_params) do
        {
          phone_number: whatsapp_channel.phone_number,
          object: 'whatsapp_business_account',
          entry: [{
            changes: [{
              value: {
                contacts: [{ profile: { name: 'Pranav' }, wa_id: '16503071063' }],
                messages: [{
                  from: '16503071063',
                  id: 'wamid.NEW_MESSAGE_ID',
                  timestamp: '1770407829',
                  text: { body: 'Need help with this campaign' },
                  type: 'text'
                }]
              }
            }]
          }]
        }.with_indifferent_access
      end

      it 'reopens the latest campaign conversation' do
        contact = create(:contact, phone_number: '+16503071063', account: whatsapp_channel.account)
        contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_channel.inbox, source_id: '16503071063')
        campaign = create(
          :campaign,
          account: whatsapp_channel.account,
          inbox: whatsapp_channel.inbox,
          template_params: {
            'name' => 'ticket_status_updated',
            'language' => 'en_US',
            'category' => 'UTILITY',
            'processed_params' => { 'body' => { 'name' => 'John' } }
          }
        )
        conversation = create(
          :conversation,
          status: :resolved,
          campaign: campaign,
          contact: contact,
          inbox: whatsapp_channel.inbox,
          contact_inbox: contact_inbox
        )
        create(
          :message,
          conversation: conversation,
          message_type: :outgoing,
          additional_attributes: { campaign_id: campaign.id },
          source_id: 'wamid.CAMPAIGN_MESSAGE_ID',
          content: 'Original campaign message'
        )

        described_class.new(inbox: whatsapp_channel.inbox, params: campaign_reply_params).perform

        reply_message = whatsapp_channel.inbox.messages.last
        expect(reply_message.content).to eq('Need help with this campaign')
        expect(reply_message.conversation_id).to eq(conversation.id)
        expect(conversation.reload).to be_open
      end
    end

    context 'when incoming WhatsApp replies answer a pending confirmation request' do
      let(:confirmation_source_id) { '77010000000' }
      let(:contact) { create(:contact, phone_number: "+#{confirmation_source_id}", account: whatsapp_channel.account) }
      let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: whatsapp_channel.inbox, source_id: confirmation_source_id) }
      let(:conversation) do
        create(
          :conversation,
          account: whatsapp_channel.account,
          inbox: whatsapp_channel.inbox,
          contact: contact,
          contact_inbox: contact_inbox
        )
      end
      let!(:confirmation_request) do
        create(
          :confirmation_request,
          account: whatsapp_channel.account,
          conversation: conversation,
          contact: contact,
          inbox: whatsapp_channel.inbox
        )
      end

      it 'resolves by interactive button reply id and keeps the visible title as message content' do
        button_params = confirmation_reply_params(
          source_id: confirmation_source_id,
          message_id: 'wamid.CONFIRM_INTERACTIVE',
          message: {
            type: 'interactive',
            interactive: {
              type: 'button_reply',
              button_reply: {
                id: "confirmation:#{confirmation_request.token}:confirmed",
                title: 'Подтвердить'
              }
            }
          }
        )

        described_class.new(inbox: whatsapp_channel.inbox, params: button_params).perform

        reply_message = whatsapp_channel.inbox.messages.last
        expect(reply_message.content).to eq('Подтвердить')
        expect(reply_message.content_attributes['interactive_reply_id']).to eq("confirmation:#{confirmation_request.token}:confirmed")
        expect(confirmation_request.reload).to be_confirmed
        expect(confirmation_request.resolution_source).to eq('button')
        expect(confirmation_request.resolved_message).to eq(reply_message)
      end

      it 'does not fall back to another pending request when a button token is unknown' do
        button_params = confirmation_reply_params(
          source_id: confirmation_source_id,
          message_id: 'wamid.UNKNOWN_CONFIRMATION_TOKEN',
          message: {
            type: 'interactive',
            interactive: {
              type: 'button_reply',
              button_reply: {
                id: 'confirmation:unknown-token:confirmed',
                title: 'Подтвердить'
              }
            }
          }
        )

        described_class.new(inbox: whatsapp_channel.inbox, params: button_params).perform

        expect(confirmation_request.reload).to be_pending
        expect(confirmation_request.resolution_source).to be_nil
      end

      it 'resolves template quick-reply buttons by button text/payload' do
        button_params = confirmation_reply_params(
          source_id: confirmation_source_id,
          message_id: 'wamid.DECLINE_TEMPLATE_BUTTON',
          message: {
            type: 'button',
            button: {
              payload: 'Отменить',
              text: 'Отменить'
            }
          }
        )

        described_class.new(inbox: whatsapp_channel.inbox, params: button_params).perform

        reply_message = whatsapp_channel.inbox.messages.last
        expect(reply_message.content).to eq('Отменить')
        expect(reply_message.content_attributes['button_payload']).to eq('Отменить')
        expect(confirmation_request.reload).to be_declined
        expect(confirmation_request.resolution_source).to eq('button')
        expect(confirmation_request.resolution_metadata).to include('resolver' => 'whatsapp_button')
      end

      it 'resolves plain text replies automatically after the inbound message is persisted' do
        text_params = confirmation_reply_params(
          source_id: confirmation_source_id,
          message_id: 'wamid.CONFIRM_TEXT',
          message: {
            type: 'text',
            text: { body: 'Да' }
          }
        )

        described_class.new(inbox: whatsapp_channel.inbox, params: text_params).perform

        reply_message = whatsapp_channel.inbox.messages.last
        expect(reply_message.content).to eq('Да')
        expect(confirmation_request.reload).to be_confirmed
        expect(confirmation_request.resolution_source).to eq('text')
        expect(confirmation_request.resolution_metadata).to include('resolver' => 'deterministic_text')
      end
    end
  end

  # Métodos auxiliares para reduzir o tamanho do exemplo

  def confirmation_reply_params(source_id:, message_id:, message:)
    message_payload = message.with_indifferent_access.merge(
      from: source_id,
      id: message_id,
      timestamp: Time.current.to_i.to_s
    )

    {
      phone_number: whatsapp_channel.phone_number,
      object: 'whatsapp_business_account',
      entry: [{
        changes: [{
          value: {
            contacts: [{ profile: { name: 'Confirmation User' }, wa_id: source_id }],
            messages: [message_payload]
          }
        }]
      }]
    }.with_indifferent_access
  end

  def stub_media_url_request
    stub_request(
      :get,
      whatsapp_channel.media_url('b1c68f38-8734-4ad3-b4a1-ef0c10d683')
    ).to_return(
      status: 200,
      body: {
        messaging_product: 'whatsapp',
        url: 'https://chatwoot-assets.local/sample.png',
        mime_type: 'image/jpeg',
        sha256: 'sha256',
        file_size: 'SIZE',
        id: 'b1c68f38-8734-4ad3-b4a1-ef0c10d683'
      }.to_json,
      headers: { 'content-type' => 'application/json' }
    )
  end

  def stub_sample_png_request
    stub_request(:get, 'https://chatwoot-assets.local/sample.png').to_return(
      status: 200,
      body: File.read('spec/assets/sample.png')
    )
  end

  def expect_conversation_created
    expect(whatsapp_channel.inbox.conversations.count).not_to eq(0)
  end

  def expect_contact_name
    expect(Contact.all.first.name).to eq('Sojan Jose')
  end

  def expect_message_content
    expect(whatsapp_channel.inbox.messages.first.content).to eq('Check out my product!')
  end

  def expect_message_has_attachment
    expect(whatsapp_channel.inbox.messages.first.attachments.present?).to be true
  end
end
