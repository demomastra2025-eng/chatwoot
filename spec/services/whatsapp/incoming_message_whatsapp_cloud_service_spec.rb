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

    it 'releases the dedup mutex when message processing raises' do
      dedup_lock = instance_double(Whatsapp::MessageDedupLock, acquire!: true, release!: true)
      service = described_class.new(inbox: whatsapp_channel.inbox, params: params)
      allow(Whatsapp::MessageDedupLock).to receive(:new).and_return(dedup_lock)
      allow(service).to receive(:set_contact).and_raise(StandardError, 'temporary failure')

      expect { service.perform }.to raise_error(StandardError, 'temporary failure')
      expect(dedup_lock).to have_received(:release!)
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

      it 'preserves the WhatsApp Cloud document filename from the webhook payload' do
        downloaded_document = downloaded_document_with_header_filename('server-header.docx-filename*=')
        stub_document_media_url_request
        allow(Down).to receive(:download).and_return(downloaded_document)

        described_class.new(
          inbox: whatsapp_channel.inbox,
          params: document_message_params(filename: 'invoice-22-06-2026.docx')
        ).perform

        attachment = whatsapp_channel.inbox.messages.last.attachments.first
        expect(attachment.file.filename.to_s).to eq('invoice-22-06-2026.docx')
        expect(attachment.extension).to eq('docx')
      ensure
        downloaded_document&.close!
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

    context 'when an order message is received' do
      it 'persists the structured order without attempting a media download' do
        order_params = params.deep_dup
        order_params[:entry][0][:changes][0][:value][:messages] = [{
          from: '2423423243',
          id: 'wamid.ORDER_MESSAGE_ID',
          timestamp: '1750096325',
          type: 'order',
          order: {
            catalog_id: 'catalog-1',
            text: 'Love these!',
            product_items: [{
              product_retailer_id: 'sku-7',
              quantity: 2,
              item_price: 30,
              currency: 'USD'
            }]
          }
        }]

        expect(Down).not_to receive(:download)

        described_class.new(inbox: whatsapp_channel.inbox, params: order_params).perform

        message = whatsapp_channel.inbox.messages.find_by!(source_id: 'wamid.ORDER_MESSAGE_ID')
        expect(message.content).to eq('Love these!')
        expect(message.attachments).to be_empty
        expect(message.content_attributes['whatsapp_order']).to eq(
          'catalog_id' => 'catalog-1',
          'text' => 'Love these!',
          'product_items' => [{
            'product_retailer_id' => 'sku-7',
            'quantity' => 2,
            'item_price' => 30,
            'currency' => 'USD'
          }]
        )
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

    context 'when BSUID identifiers are present' do
      it 'creates a contact and conversation when only BSUID is present' do
        bsuid_params = {
          phone_number: whatsapp_channel.phone_number,
          object: 'whatsapp_business_account',
          entry: [{
            changes: [{
              value: {
                contacts: [{
                  profile: { name: 'Muhsin', username: 'muhsin' },
                  user_id: 'IN.2081978709342942',
                  parent_user_id: 'IN.ENT.9081726354'
                }],
                messages: [{
                  from_user_id: 'IN.2081978709342942',
                  from_parent_user_id: 'IN.ENT.9081726354',
                  id: 'wamid.cloud-bsuid-only-message',
                  text: { body: 'testing bsuid' },
                  timestamp: '1778579582',
                  type: 'text'
                }]
              }
            }]
          }]
        }.with_indifferent_access

        described_class.new(inbox: whatsapp_channel.inbox, params: bsuid_params).perform

        contact_inbox = whatsapp_channel.inbox.contact_inboxes.find_by!(source_id: 'IN.2081978709342942')
        parent_contact_inbox = whatsapp_channel.inbox.contact_inboxes.find_by!(source_id: 'IN.ENT.9081726354')
        contact = contact_inbox.contact
        expect(whatsapp_channel.inbox.conversations.count).to eq(1)
        expect(whatsapp_channel.inbox.messages.first.content).to eq('testing bsuid')
        expect(contact).to have_attributes(name: 'Muhsin', phone_number: nil)
        expect(contact.additional_attributes).to include(
          'social_whatsapp_user_name' => 'muhsin',
          'social_profiles' => { 'whatsapp' => 'muhsin' }
        )
        expect(parent_contact_inbox.contact).to eq(contact)
      end

      it 'links phone and BSUID source ids to the same contact' do
        phone_with_bsuid_params = {
          phone_number: whatsapp_channel.phone_number,
          object: 'whatsapp_business_account',
          entry: [{
            changes: [{
              value: {
                contacts: [{ profile: { name: 'Muhsin' }, wa_id: '919745786257', user_id: 'IN.2081978709342942' }],
                messages: [{
                  from: '919745786257',
                  from_user_id: 'IN.2081978709342942',
                  id: 'wamid.cloud-phone-bsuid-message',
                  text: { body: 'phone and bsuid' },
                  timestamp: '1778579582',
                  type: 'text'
                }]
              }
            }]
          }]
        }.with_indifferent_access
        bsuid_only_params = {
          phone_number: whatsapp_channel.phone_number,
          object: 'whatsapp_business_account',
          entry: [{
            changes: [{
              value: {
                contacts: [{ profile: { name: 'Muhsin' }, user_id: 'IN.2081978709342942' }],
                messages: [{
                  from_user_id: 'IN.2081978709342942',
                  id: 'wamid.cloud-bsuid-follow-up-message',
                  text: { body: 'bsuid only' },
                  timestamp: '1778579583',
                  type: 'text'
                }]
              }
            }]
          }]
        }.with_indifferent_access

        described_class.new(inbox: whatsapp_channel.inbox, params: phone_with_bsuid_params).perform
        phone_contact_inbox = whatsapp_channel.inbox.contact_inboxes.find_by!(source_id: '919745786257')
        bsuid_contact_inbox = whatsapp_channel.inbox.contact_inboxes.find_by!(source_id: 'IN.2081978709342942')

        expect { described_class.new(inbox: whatsapp_channel.inbox, params: bsuid_only_params).perform }.not_to raise_error
        expect(whatsapp_channel.inbox.contact_inboxes.count).to eq(2)
        expect(whatsapp_channel.inbox.messages.pluck(:content)).to contain_exactly('phone and bsuid', 'bsuid only')
        expect(bsuid_contact_inbox.contact).to eq(phone_contact_inbox.contact)
      end
    end

    context 'when Click-to-WhatsApp Ads referral is present' do
      let(:ctwa_params) do
        {
          phone_number: whatsapp_channel.phone_number,
          object: 'whatsapp_business_account',
          entry: [{
            changes: [{
              value: {
                contacts: [{ profile: { name: 'Meta Ads Lead' }, wa_id: '77010002030' }],
                messages: [{
                  from: '77010002030',
                  id: 'wamid.CTWA_MESSAGE_ID',
                  timestamp: '1770407829',
                  text: { body: 'Interested in the offer' },
                  type: 'text',
                  referral: {
                    source_url: 'https://fb.me/1AbCdEf',
                    source_type: 'ad',
                    source_id: '23877210000123456',
                    headline: 'Premium consultation',
                    body: 'Book a visit today',
                    media_type: 'image',
                    image_url: 'https://lookaside.fbsbx.com/image.jpg',
                    thumbnail_url: 'https://lookaside.fbsbx.com/thumb.jpg',
                    ctwa_clid: 'ARaD-ctwa-click-id-123'
                  }
                }]
              }
            }]
          }]
        }.with_indifferent_access
      end

      it 'persists the normalized referral on the message, conversation, and source table' do
        described_class.new(inbox: whatsapp_channel.inbox, params: ctwa_params).perform

        message = whatsapp_channel.inbox.messages.find_by!(source_id: 'wamid.CTWA_MESSAGE_ID')
        referral_payload = message.content_attributes['meta_referral']
        referral = MetaAdReferral.find_by!(message: message)

        expect(referral_payload).to include(
          'provider' => 'whatsapp',
          'attribution_type' => 'click_to_whatsapp_ad',
          'ctwa_clid' => 'ARaD-ctwa-click-id-123',
          'source_id' => '23877210000123456',
          'source_url' => 'https://fb.me/1AbCdEf',
          'headline' => 'Premium consultation'
        )
        expect(referral).to have_attributes(
          provider: 'whatsapp',
          attribution_type: 'click_to_whatsapp_ad',
          provider_message_id: 'wamid.CTWA_MESSAGE_ID',
          ctwa_clid: 'ARaD-ctwa-click-id-123',
          source_id: '23877210000123456',
          ad_id: '23877210000123456'
        )
        expect(referral.raw_referral['ctwa_clid']).to eq('ARaD-ctwa-click-id-123')
        expect(message.conversation.additional_attributes.dig('meta_ad_referral', 'ctwa_clid')).to eq('ARaD-ctwa-click-id-123')
        expect(message.conversation.contact.additional_attributes).not_to have_key('last_meta_ad_referral')
      end

      it 'is idempotent for duplicate provider message ids' do
        described_class.new(inbox: whatsapp_channel.inbox, params: ctwa_params).perform
        described_class.new(inbox: whatsapp_channel.inbox, params: ctwa_params).perform

        expect(MetaAdReferral.where(provider_message_id: 'wamid.CTWA_MESSAGE_ID').count).to eq(1)
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
              'processed_params' => { 'body' => { 'name' => 'John', 'last_name' => 'Doe', 'ticket_id' => 'TCK-1' } }
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
            'processed_params' => { 'body' => { 'name' => 'John', 'last_name' => 'Doe', 'ticket_id' => 'TCK-1' } }
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

    context 'when WhatsApp Cloud delivery status webhooks arrive out of order' do
      it 'normalizes Meta played status to read' do
        message = create(:message, inbox: whatsapp_channel.inbox, message_type: :outgoing, status: :delivered, source_id: 'wamid.PLAYED_MESSAGE')

        described_class.new(
          inbox: whatsapp_channel.inbox,
          params: status_update_params(source_id: message.source_id, status: 'played')
        ).perform

        expect(message.reload).to be_read
      end

      it 'does not downgrade a delivered message back to sent' do
        message = create(:message, inbox: whatsapp_channel.inbox, message_type: :outgoing, status: :delivered, source_id: 'wamid.DELIVERED_MESSAGE')

        described_class.new(
          inbox: whatsapp_channel.inbox,
          params: status_update_params(
            source_id: message.source_id,
            status: 'sent',
            delivery_metadata: {
              conversation: { id: 'conversation-1', origin: { type: 'marketing' } },
              pricing: { billable: true, category: 'marketing', pricing_model: 'PMP' }
            }
          )
        ).perform

        expect(message.reload).to be_delivered
        expect(message.content_attributes['whatsapp_delivery']).to eq(
          'conversation' => { 'id' => 'conversation-1', 'origin' => { 'type' => 'marketing' } },
          'pricing' => { 'billable' => true, 'category' => 'marketing', 'pricing_model' => 'PMP' }
        )
      end

      it 'does not downgrade a read message back to delivered' do
        message = create(:message, inbox: whatsapp_channel.inbox, message_type: :outgoing, status: :read, source_id: 'wamid.READ_MESSAGE')

        described_class.new(
          inbox: whatsapp_channel.inbox,
          params: status_update_params(source_id: message.source_id, status: 'delivered')
        ).perform

        expect(message.reload).to be_read
      end

      it 'still upgrades a sent message to delivered' do
        message = create(:message, inbox: whatsapp_channel.inbox, message_type: :outgoing, status: :sent, source_id: 'wamid.SENT_MESSAGE')

        described_class.new(
          inbox: whatsapp_channel.inbox,
          params: status_update_params(source_id: message.source_id, status: 'delivered')
        ).perform

        expect(message.reload).to be_delivered
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

      it 'does not resolve confirmations while importing historical messages' do
        text_params = confirmation_reply_params(
          source_id: confirmation_source_id,
          message_id: 'wamid.HISTORICAL_CONFIRM_TEXT',
          message: { type: 'text', text: { body: 'Да' } }
        )
        previous_value = Current.suppress_runtime_events
        Current.suppress_runtime_events = true

        described_class.new(inbox: whatsapp_channel.inbox, params: text_params).perform

        expect(confirmation_request.reload).to be_pending
      ensure
        Current.suppress_runtime_events = previous_value
      end
    end
  end

  # Métodos auxiliares para reduzir o tamanho do exemplo

  def status_update_params(source_id:, status:, delivery_metadata: {})
    {
      phone_number: whatsapp_channel.phone_number,
      object: 'whatsapp_business_account',
      entry: [{
        changes: [{
          value: {
            statuses: [{ id: source_id, status: status, timestamp: Time.current.to_i.to_s }.merge(delivery_metadata)]
          }
        }]
      }]
    }.with_indifferent_access
  end

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

  def document_message_params(filename:)
    params.deep_dup.tap do |payload|
      message = payload[:entry][0][:changes][0][:value][:messages][0]
      message.delete(:image)
      message.merge!(
        id: 'wamid.DOCUMENT_FILENAME_MESSAGE',
        document: {
          id: 'document-media-id',
          filename: filename,
          mime_type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
          sha256: 'sha256'
        },
        type: 'document'
      )
    end
  end

  def downloaded_document_with_header_filename(filename)
    tempfile = Tempfile.new(['whatsapp-cloud-document', '.docx'])
    tempfile.binmode
    tempfile.write('fake docx')
    tempfile.rewind
    tempfile.define_singleton_method(:original_filename) { filename }
    tempfile.define_singleton_method(:content_type) { 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' }
    tempfile
  end

  def stub_document_media_url_request
    stub_request(
      :get,
      whatsapp_channel.media_url('document-media-id')
    ).to_return(
      status: 200,
      body: {
        messaging_product: 'whatsapp',
        url: 'https://chatwoot-assets.local/sample.docx',
        mime_type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        sha256: 'sha256',
        file_size: 'SIZE',
        id: 'document-media-id'
      }.to_json,
      headers: { 'content-type' => 'application/json' }
    )
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
