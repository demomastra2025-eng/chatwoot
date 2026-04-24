require 'rails_helper'

RSpec.describe WhatsappWeb::IncomingMessageService do
  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  after do
    Redis::Alfred.scan_each(match: 'MESSAGE_SOURCE_KEY::*') do |key|
      Redis::Alfred.delete(key)
    end
    Redis::Alfred.scan_each(match: 'WHATSAPP_WEB_PENDING_MESSAGE_STATUS::*') do |key|
      Redis::Alfred.delete(key)
    end
  end

  describe '#perform' do
    let(:channel) { create(:channel_whatsapp_web) }
    let(:inbox) { channel.inbox }
    let(:contact) { create(:contact, account: inbox.account, phone_number: '+15551234567') }
    let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: '15551234567') }
    let(:conversation) { create(:conversation, account: inbox.account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
    let(:base_payload) do
      {
        key: {
          id: 'REPLY_MESSAGE_ID',
          remoteJid: '15551234567@s.whatsapp.net'
        },
        pushName: 'Reply Author',
        message: {
          conversation: 'This is a reply'
        }
      }.with_indifferent_access
    end

    let!(:original_message) do
      create(:message, account: inbox.account, inbox: inbox, conversation: conversation, source_id: 'ORIGINAL_MESSAGE_ID')
    end

    it 'maps top-level contextInfo replies to in_reply_to' do
      described_class.new(inbox: inbox, params: base_payload.deep_merge(contextInfo: { stanzaId: 'ORIGINAL_MESSAGE_ID' })).perform

      reply_message = conversation.messages.find_by(source_id: 'REPLY_MESSAGE_ID')
      expect(reply_message.content_attributes['in_reply_to']).to eq(original_message.id)
      expect(reply_message.content_attributes['in_reply_to_external_id']).to eq('ORIGINAL_MESSAGE_ID')
    end

    it 'maps nested message.contextInfo replies to in_reply_to' do
      params = base_payload.deep_merge(
        message: {
          conversation: 'Nested reply',
          contextInfo: { stanzaId: 'ORIGINAL_MESSAGE_ID' }
        }
      )

      described_class.new(inbox: inbox, params: params).perform

      reply_message = conversation.messages.find_by(source_id: 'REPLY_MESSAGE_ID')
      expect(reply_message.content).to eq('Nested reply')
      expect(reply_message.content_attributes['in_reply_to']).to eq(original_message.id)
      expect(reply_message.content_attributes['in_reply_to_external_id']).to eq('ORIGINAL_MESSAGE_ID')
    end

    it 'starts a new conversation as pending when the channel is configured that way' do
      pending_channel = create(:channel_whatsapp_web, conversation_pending: true)

      described_class.new(
        inbox: pending_channel.inbox,
        params: {
          key: {
            id: 'pending-message-1',
            remoteJid: '15557654321@s.whatsapp.net'
          },
          pushName: 'Pending Author',
          message: {
            conversation: 'Need help'
          }
        }.with_indifferent_access
      ).perform

      expect(pending_channel.inbox.conversations.last.status).to eq('pending')
    end

    it 'creates outgoing echo messages for mobile text sends' do
      described_class.new(
        inbox: inbox,
        params: {
          key: {
            id: 'OUTGOING_TEXT_1',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: true
          },
          message: {
            extendedTextMessage: {
              text: 'Sent from the phone'
            }
          }
        }.with_indifferent_access,
        outgoing_echo: true
      ).perform

      outgoing_message = conversation.messages.find_by(source_id: 'OUTGOING_TEXT_1')
      expect(outgoing_message).to be_present
      expect(outgoing_message.message_type).to eq('outgoing')
      expect(outgoing_message.status).to eq('delivered')
      expect(outgoing_message.sender).to be_nil
      expect(outgoing_message.content).to eq('Sent from the phone')
      expect(outgoing_message.content_attributes['external_echo']).to eq(true)
    end

    it 'does not overwrite the contact name with an outgoing echo pushName' do
      contact.update!(name: 'Alice')

      described_class.new(
        inbox: inbox,
        params: {
          key: {
            id: 'OUTGOING_TEXT_NAME_GUARD',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: true
          },
          pushName: 'Akhan',
          message: {
            extendedTextMessage: {
              text: 'Outgoing name should stay low trust'
            }
          }
        }.with_indifferent_access,
        outgoing_echo: true
      ).perform

      expect(contact.reload.name).to eq('Alice')
      expect(contact.additional_attributes['last_provider_display_name']).to be_nil
    end

    it 'applies a cached provider status when the message arrives after a status update' do
      WhatsappWeb::PendingMessageStatusCache.new(
        inbox_id: inbox.id,
        source_id: 'OUTGOING_TEXT_2'
      ).write('READ')

      described_class.new(
        inbox: inbox,
        params: {
          key: {
            id: 'OUTGOING_TEXT_2',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: true
          },
          message: {
            extendedTextMessage: {
              text: 'Sent from the phone after a cached status'
            }
          }
        }.with_indifferent_access,
        outgoing_echo: true
      ).perform

      outgoing_message = conversation.messages.find_by(source_id: 'OUTGOING_TEXT_2')
      expect(outgoing_message).to be_present
      expect(outgoing_message.status).to eq('read')
      expect(
        WhatsappWeb::PendingMessageStatusCache.new(
          inbox_id: inbox.id,
          source_id: 'OUTGOING_TEXT_2'
        ).peek
      ).to be_nil
    end

    it 'treats unique-index races as idempotent when the message was already created concurrently' do
      create(
        :message,
        account: inbox.account,
        inbox: inbox,
        conversation: conversation,
        source_id: 'RACE_MESSAGE_1',
        message_type: :incoming
      )

      service = described_class.new(
        inbox: inbox,
        params: {
          key: {
            id: 'RACE_MESSAGE_1',
            remoteJid: '15551234567@s.whatsapp.net'
          },
          pushName: 'Race Winner',
          message: {
            conversation: 'Created elsewhere first'
          }
        }.with_indifferent_access
      )

      allow(service).to receive(:find_message_by_source_id).and_return(nil)
      allow(service).to receive(:lock_message_source_id!).and_return(true)

      expect { service.perform }.not_to raise_error
      expect(inbox.messages.where(source_id: 'RACE_MESSAGE_1').count).to eq(1)
    end

    it 'creates outgoing echo media messages without retrying when provider media URL is expired' do
      allow(Down).to receive(:download)
        .with('https://mmg.whatsapp.net/expired-media')
        .and_raise(Down::ClientError.new('403 Forbidden'))

      expect do
        described_class.new(
          inbox: inbox,
          params: {
            key: {
              id: 'OUTGOING_EXPIRED_MEDIA_1',
              remoteJid: '15551234567@s.whatsapp.net',
              fromMe: true
            },
            message: {
              imageMessage: {
                caption: 'Phone photo with expired provider media',
                mimetype: 'image/jpeg',
                fileName: 'expired.jpg',
                mediaUrl: 'https://mmg.whatsapp.net/expired-media'
              }
            }
          }.with_indifferent_access,
          outgoing_echo: true
        ).perform
      end.not_to raise_error

      outgoing_message = conversation.messages.find_by(source_id: 'OUTGOING_EXPIRED_MEDIA_1')
      expect(outgoing_message).to be_present
      expect(outgoing_message.message_type).to eq('outgoing')
      expect(outgoing_message.status).to eq('delivered')
      expect(outgoing_message.content).to eq('Phone photo with expired provider media')
      expect(outgoing_message.content_attributes['external_echo']).to be(true)
      expect(outgoing_message.attachments).to be_empty
    end

    it 'creates outgoing echo media messages for mobile sends' do
      image_base64 = Base64.strict_encode64(File.binread(Rails.root.join('spec/assets/avatar.png')))

      described_class.new(
        inbox: inbox,
        params: {
          key: {
            id: 'OUTGOING_MEDIA_1',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: true
          },
          message: {
            imageMessage: {
              caption: 'Phone photo',
              mimetype: 'image/png',
              fileName: 'avatar.png'
            },
            base64: image_base64
          }
        }.with_indifferent_access,
        outgoing_echo: true
      ).perform

      outgoing_message = conversation.messages.find_by(source_id: 'OUTGOING_MEDIA_1')
      expect(outgoing_message).to be_present
      expect(outgoing_message.message_type).to eq('outgoing')
      expect(outgoing_message.content).to eq('Phone photo')
      expect(outgoing_message.content_attributes['external_echo']).to eq(true)
      expect(outgoing_message.attachments.size).to eq(1)
      expect(outgoing_message.attachments.first.file_type).to eq('image')
      expect(outgoing_message.attachments.first.file.attached?).to be(true)
    end

    it 'creates outgoing echo document messages with captions from the mobile client' do
      document_base64 = Base64.strict_encode64(File.binread(Rails.root.join('spec/fixtures/files/sample.pdf')))

      described_class.new(
        inbox: inbox,
        params: {
          key: {
            id: 'OUTGOING_DOCUMENT_1',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: true
          },
          message: {
            documentWithCaptionMessage: {
              message: {
                documentMessage: {
                  caption: 'Contract draft',
                  mimetype: 'application/pdf',
                  fileName: 'sample.pdf'
                }
              }
            },
            base64: document_base64
          }
        }.with_indifferent_access,
        outgoing_echo: true
      ).perform

      outgoing_message = conversation.messages.find_by(source_id: 'OUTGOING_DOCUMENT_1')
      expect(outgoing_message).to be_present
      expect(outgoing_message.message_type).to eq('outgoing')
      expect(outgoing_message.content).to eq('Contract draft')
      expect(outgoing_message.content_attributes['external_echo']).to eq(true)
      expect(outgoing_message.attachments.size).to eq(1)
      expect(outgoing_message.attachments.first.file_type).to eq('file')
      expect(outgoing_message.attachments.first.file.attached?).to be(true)
    end

    it 'creates live conversations for lid-only contacts so they remain replyable before phone resolution' do
      described_class.new(
        inbox: inbox,
        params: {
          key: {
            id: 'LID_ONLY_MESSAGE_1',
            remoteJid: '143907392331785@lid',
            remoteLid: '143907392331785@lid'
          },
          pushName: 'LID User',
          message: {
            conversation: 'Hello from a provisional LID'
          }
        }.with_indifferent_access
      ).perform

      lid_contact_inbox = inbox.contact_inboxes.find_by(source_id: '143907392331785@lid')
      lid_message = inbox.messages.find_by(source_id: 'LID_ONLY_MESSAGE_1')

      expect(lid_contact_inbox).to be_present
      expect(lid_contact_inbox.contact.phone_number).to be_nil
      expect(lid_message).to be_present
      expect(lid_message.conversation.contact_inbox_id).to eq(lid_contact_inbox.id)
    end

    it 'reuses the same conversation when a provisional lid contact later resolves to a canonical phone jid' do
      described_class.new(
        inbox: inbox,
        params: {
          key: {
            id: 'LID_ALIAS_MESSAGE_1',
            remoteJid: '143907392331785@lid',
            remoteLid: '143907392331785@lid'
          },
          pushName: 'Alias Contact',
          message: {
            conversation: 'First via LID'
          }
        }.with_indifferent_access
      ).perform

      first_message = inbox.messages.find_by(source_id: 'LID_ALIAS_MESSAGE_1')

      described_class.new(
        inbox: inbox,
        params: {
          key: {
            id: 'LID_ALIAS_MESSAGE_2',
            remoteJid: '15551234567@s.whatsapp.net',
            remoteLid: '143907392331785@lid'
          },
          pushName: 'Alias Contact',
          message: {
            conversation: 'Then via PN'
          }
        }.with_indifferent_access
      ).perform

      second_message = inbox.messages.find_by(source_id: 'LID_ALIAS_MESSAGE_2')

      expect(first_message).to be_present
      expect(second_message).to be_present
      expect(second_message.conversation_id).to eq(first_message.conversation_id)
      expect(second_message.conversation.contact.reload.phone_number).to eq('+15551234567')
    end
  end
end
