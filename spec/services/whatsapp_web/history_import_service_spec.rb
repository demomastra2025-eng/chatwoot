require 'rails_helper'

RSpec.describe WhatsappWeb::HistoryImportService do
  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  let(:channel) { create(:channel_whatsapp_web) }

  it 'imports history messages without enqueuing outbound replies or runtime fanout jobs' do
    result = nil
    channel
    clear_enqueued_jobs
    allow_any_instance_of(Inbox).to receive(:enable_auto_assignment?).and_return(true)
    allow_any_instance_of(Inbox).to receive(:auto_assignment_v2_enabled?).and_return(true)

    expect do
      result = described_class.new(
        channel: channel,
        records: [
          {
            key: {
              id: 'history-msg-1',
              remoteJid: '15551234567@s.whatsapp.net',
              fromMe: false
            },
            pushName: 'Alice',
            messageTimestamp: 1.hour.ago.to_i,
            message: {
              conversation: 'Imported from history'
            }
          }
        ]
      ).perform
    end.not_to have_enqueued_job(SendReplyJob)

    expect(enqueued_jobs.map { |job| job[:job] }).not_to include(EventDispatcherJob)
    expect(enqueued_jobs.map { |job| job[:job] }).not_to include(AutoAssignment::AssignmentJob)

    message = channel.inbox.messages.find_by(source_id: 'history-msg-1')

    expect(result).to eq(messages_imported: 1, contacts_touched: 1)
    expect(message).to be_present
    expect(message.content).to eq('Imported from history')
    expect(message.message_type).to eq('incoming')
    expect(message.content_attributes['imported_history']).to eq(true)
  end

  it 'keeps imports idempotent when the same provider message appears multiple times' do
    result = described_class.new(
      channel: channel,
      records: [
        {
          key: {
            id: 'history-msg-duplicate',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: false
          },
          pushName: 'Alice',
          messageTimestamp: 1.hour.ago.to_i,
          message: {
            conversation: 'Imported from history'
          }
        },
        {
          key: {
            id: 'history-msg-duplicate',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: false
          },
          pushName: 'Alice',
          messageTimestamp: 59.minutes.ago.to_i,
          message: {
            conversation: 'Imported from history again'
          }
        }
      ]
    ).perform

    expect(result).to eq(messages_imported: 1, contacts_touched: 1)
    expect(channel.inbox.messages.where(source_id: 'history-msg-duplicate').count).to eq(1)
  end

  it 'skips records outside the configured lookback window' do
    channel.update!(history_lookback_days: 7)

    result = described_class.new(
      channel: channel,
      records: [
        {
          key: {
            id: 'history-msg-old',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: false
          },
          pushName: 'Alice',
          messageTimestamp: 14.days.ago.to_i,
          message: {
            conversation: 'Too old'
          }
        }
      ]
    ).perform

    expect(result).to eq(messages_imported: 0, contacts_touched: 0)
    expect(channel.inbox.messages.find_by(source_id: 'history-msg-old')).to be_nil
  end

  it 'imports old records when lookback days are disabled' do
    channel.update!(history_lookback_days: 0)

    result = described_class.new(
      channel: channel,
      records: [
        {
          key: {
            id: 'history-msg-unlimited',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: false
          },
          pushName: 'Alice',
          messageTimestamp: 14.days.ago.to_i,
          message: {
            conversation: 'Still importable'
          }
        }
      ]
    ).perform

    expect(result).to eq(messages_imported: 1, contacts_touched: 1)
    expect(channel.inbox.messages.find_by(source_id: 'history-msg-unlimited')).to be_present
  end

  it 'keeps imported incoming and device-sent outgoing history in the same conversation with provider timestamps' do
    incoming_timestamp = 2.hours.ago.change(usec: 0)
    outgoing_timestamp = 90.minutes.ago.change(usec: 0)

    described_class.new(
      channel: channel,
      records: [
        {
          key: {
            id: 'history-msg-incoming-device-check',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: false
          },
          pushName: 'Alice',
          messageTimestamp: incoming_timestamp.to_i,
          message: {
            conversation: 'Incoming from history'
          }
        },
        {
          key: {
            id: 'history-msg-outgoing-device-check',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: true
          },
          pushName: 'Alice',
          messageTimestamp: outgoing_timestamp.to_i,
          message: {
            extendedTextMessage: {
              text: 'Outgoing from device history'
            }
          }
        }
      ]
    ).perform

    expect(channel.inbox.conversations.count).to eq(1)

    conversation = channel.inbox.conversations.last
    messages = conversation.messages.reorder(created_at: :asc)

    expect(conversation.contact_inbox.source_id).to eq('15551234567')
    expect(messages.map(&:message_type)).to eq(%w[incoming outgoing])
    expect(messages.map(&:content)).to eq(
      ['Incoming from history', 'Outgoing from device history']
    )
    expect(messages.first.created_at.to_i).to eq(incoming_timestamp.to_i)
    expect(messages.last.created_at.to_i).to eq(outgoing_timestamp.to_i)
    expect(messages.last.sender).to be_nil
    expect(messages.last.content_attributes['external_echo']).to eq(true)
    expect(messages.last.content_attributes['imported_history']).to eq(true)
  end

  it 'skips records from ignored jids' do
    channel.update!(ignore_jids: ['15559876543@s.whatsapp.net'])

    result = described_class.new(
      channel: channel,
      records: [
        {
          key: {
            id: 'history-msg-ignored',
            remoteJid: '15559876543@s.whatsapp.net',
            fromMe: false
          },
          pushName: 'Ignored',
          messageTimestamp: 1.hour.ago.to_i,
          message: {
            conversation: 'Should be skipped'
          }
        }
      ]
    ).perform

    expect(result).to eq(messages_imported: 0, contacts_touched: 0)
    expect(channel.inbox.messages.find_by(source_id: 'history-msg-ignored')).to be_nil
  end

  it 'skips placeholder records without renderable payload' do
    result = described_class.new(
      channel: channel,
      records: [
        {
          key: {
            id: 'history-msg-placeholder',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: false
          },
          pushName: 'Alice',
          messageTimestamp: 1.hour.ago.to_i,
          message: {
            placeholderMessage: {
              type: 0
            }
          }
        }
      ]
    ).perform

    expect(result).to eq(messages_imported: 0, contacts_touched: 0)
    expect(channel.inbox.messages.find_by(source_id: 'history-msg-placeholder')).to be_nil
  end

  it 'imports template history messages using hydrated template content' do
    result = described_class.new(
      channel: channel,
      records: [
        {
          key: {
            id: 'history-msg-template',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: false
          },
          pushName: 'Alice',
          messageTimestamp: 1.hour.ago.to_i,
          message: {
            templateMessage: {
              hydratedFourRowTemplate: {
                hydratedTitleText: 'Template title',
                hydratedContentText: 'Template body'
              }
            }
          }
        }
      ]
    ).perform

    imported_message = channel.inbox.messages.find_by(source_id: 'history-msg-template')

    expect(result).to eq(messages_imported: 1, contacts_touched: 1)
    expect(imported_message).to be_present
    expect(imported_message.content).to eq("*Template title*\nTemplate body")
  end

  it 'imports buttons history messages using content text' do
    result = described_class.new(
      channel: channel,
      records: [
        {
          key: {
            id: 'history-msg-buttons',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: false
          },
          pushName: 'Alice',
          messageTimestamp: 1.hour.ago.to_i,
          message: {
            buttonsMessage: {
              contentText: 'Please choose an option'
            }
          }
        }
      ]
    ).perform

    imported_message = channel.inbox.messages.find_by(source_id: 'history-msg-buttons')

    expect(result).to eq(messages_imported: 1, contacts_touched: 1)
    expect(imported_message).to be_present
    expect(imported_message.content).to eq('Please choose an option')
  end

  it 'imports button reply history messages and keeps the replied stanza id' do
    result = described_class.new(
      channel: channel,
      records: [
        {
          key: {
            id: 'history-msg-buttons-response',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: false
          },
          pushName: 'Alice',
          messageTimestamp: 1.hour.ago.to_i,
          message: {
            buttonsResponseMessage: {
              selectedButtonId: 'btn-1',
              selectedDisplayText: 'Choice 1',
              contextInfo: {
                stanzaId: 'quoted-history-msg'
              }
            }
          }
        }
      ]
    ).perform

    imported_message = channel.inbox.messages.find_by(source_id: 'history-msg-buttons-response')

    expect(result).to eq(messages_imported: 1, contacts_touched: 1)
    expect(imported_message).to be_present
    expect(imported_message.content).to eq('Choice 1')
    expect(imported_message.content_attributes['in_reply_to_external_id']).to eq('quoted-history-msg')
  end

  it 'persists a media-only stub when attachment download fails' do
    allow(Down).to receive(:download).and_raise(StandardError, 'expired media URL')
    provider_service = instance_double(
      WhatsappWeb::Providers::EvolutionService,
      prefer_provider_media_for_history?: true,
      fetch_message_media: nil
    )
    allow(provider_service).to receive(:fetch_message_media).and_raise(StandardError, 'provider media unavailable')
    allow(provider_service).to receive(:fetch_message_by_source_id).and_return(nil)
    allow(channel).to receive(:provider_service).and_return(provider_service)

    result = described_class.new(
      channel: channel,
      records: [
        {
          key: {
            id: 'history-msg-audio',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: false
          },
          pushName: 'Alice',
          messageTimestamp: 1.hour.ago.to_i,
          message: {
            audioMessage: {
              url: 'https://example.com/audio.ogg',
              mimetype: 'audio/ogg'
            }
          }
        }
      ]
    ).perform

    imported_message = channel.inbox.messages.find_by(source_id: 'history-msg-audio')

    expect(result).to eq(messages_imported: 1, contacts_touched: 1)
    expect(imported_message).to be_present
    expect(imported_message.content).to eq('[Attachment]')
    expect(imported_message.attachments).to be_empty
    expect(imported_message.content_attributes['history_attachment']).to include(
      'unavailable' => true,
      'kind' => 'audio',
      'mimetype' => 'audio/ogg',
      'media_url' => 'https://example.com/audio.ogg'
    )
  end

  it 'prefers provider media fetch before direct media URL downloads' do
    expect(Down).not_to receive(:download)
    provider_service = instance_double(
      WhatsappWeb::Providers::EvolutionService,
      prefer_provider_media_for_history?: true
    )
    allow(provider_service).to receive(:fetch_message_media).and_return(
      {
        base64: Base64.strict_encode64('image-bytes'),
        fileName: 'provider-image.png',
        mimetype: 'image/png'
      }
    )
    allow(channel).to receive(:provider_service).and_return(provider_service)

    result = described_class.new(
      channel: channel,
      records: [
        {
          key: {
            id: 'history-msg-image-provider-fallback',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: false
          },
          pushName: 'Alice',
          messageTimestamp: 1.hour.ago.to_i,
          message: {
            imageMessage: {
              url: 'https://example.com/image.png',
              mimetype: 'image/png',
              fileName: 'image.png'
            }
          }
        }
      ]
    ).perform

    imported_message = channel.inbox.messages.find_by(source_id: 'history-msg-image-provider-fallback')

    expect(result).to eq(messages_imported: 1, contacts_touched: 1)
    expect(imported_message).to be_present
    expect(imported_message.attachments.count).to eq(1)
    expect(imported_message.attachments.first.file_type).to eq('image')
    expect(imported_message.attachments.first.file.attached?).to be(true)
    expect(imported_message.content_attributes['history_attachment']).to be_nil
  end

  it 'keeps a placeholder when the provider reports historical media as unavailable' do
    expect(Down).not_to receive(:download)
    provider_service = instance_double(
      WhatsappWeb::Providers::EvolutionService,
      prefer_provider_media_for_history?: true
    )
    allow(provider_service).to receive(:fetch_message_media).and_return(
      {
        unavailable: true,
        reason: 'media_unavailable',
        statusCode: 410
      }
    )
    allow(provider_service).to receive(:fetch_message_by_source_id).and_return(nil)
    allow(channel).to receive(:provider_service).and_return(provider_service)

    result = described_class.new(
      channel: channel,
      records: [
        {
          key: {
            id: 'history-msg-image-unavailable',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: false
          },
          pushName: 'Alice',
          messageTimestamp: 1.hour.ago.to_i,
          message: {
            imageMessage: {
              url: 'https://example.com/missing-image.png',
              mimetype: 'image/png',
              fileName: 'missing-image.png'
            }
          }
        }
      ]
    ).perform

    imported_message = channel.inbox.messages.find_by(source_id: 'history-msg-image-unavailable')

    expect(result).to eq(messages_imported: 1, contacts_touched: 1)
    expect(imported_message).to be_present
    expect(imported_message.content).to eq('[Attachment]')
    expect(imported_message.attachments).to be_empty
    expect(imported_message.content_attributes['history_attachment']).to include(
      'unavailable' => true,
      'kind' => 'image',
      'mimetype' => 'image/png',
      'media_url' => 'https://example.com/missing-image.png'
    )
  end

  it 'reuses the existing conversation when one appears while the contact inbox lock is held' do
    contact = create(:contact, account: channel.account)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: channel.inbox, source_id: '15551234567')
    service = described_class.new(channel: channel, records: [])
    message_time = 1.hour.ago.change(usec: 0)
    existing_conversation = nil

    allow(contact_inbox).to receive(:with_lock).and_wrap_original do |method, &block|
      existing_conversation ||= create(
        :conversation,
        account: channel.account,
        inbox: channel.inbox,
        contact: contact,
        contact_inbox: contact_inbox
      )
      method.call(&block)
    end

    conversation = service.send(:find_or_create_conversation, contact_inbox, message_time)

    expect(conversation.id).to eq(existing_conversation.id)
    expect(contact_inbox.conversations.count).to eq(1)
  end

  it 'imports associated child media messages as attachments' do
    video_file = Tempfile.new(['whatsapp-web-history', '.mp4'])
    video_file.binmode
    video_file.write('fake-video')
    video_file.rewind
    allow(Down).to receive(:download).and_return(video_file)
    provider_service = instance_double(
      WhatsappWeb::Providers::EvolutionService,
      prefer_provider_media_for_history?: false
    )
    allow(channel).to receive(:provider_service).and_return(provider_service)

    result = described_class.new(
      channel: channel,
      records: [
        {
          key: {
            id: 'history-msg-associated-video',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: false
          },
          pushName: 'Alice',
          messageTimestamp: 1.hour.ago.to_i,
          message: {
            associatedChildMessage: {
              message: {
                videoMessage: {
                  url: 'https://example.com/video.mp4',
                  mimetype: 'video/mp4',
                  fileName: 'clip.mp4'
                }
              }
            }
          }
        }
      ]
    ).perform

    imported_message = channel.inbox.messages.find_by(source_id: 'history-msg-associated-video')

    expect(result).to eq(messages_imported: 1, contacts_touched: 1)
    expect(imported_message).to be_present
    expect(imported_message.attachments.count).to eq(1)
    expect(imported_message.attachments.first.file_type).to eq('video')
  ensure
    video_file&.close!
  end

  it 'imports lid-only direct history so the conversation remains replyable before phone resolution' do
    result = described_class.new(
      channel: channel,
      records: [
        {
          key: {
            id: 'history-msg-lid-only',
            remoteJid: '143907392331785@lid',
            remoteLid: '143907392331785@lid',
            fromMe: false
          },
          pushName: 'LID User',
          messageTimestamp: 1.hour.ago.to_i,
          message: {
            conversation: 'Imported from a provisional LID identity'
          }
        }
      ]
    ).perform

    imported_message = channel.inbox.messages.find_by(source_id: 'history-msg-lid-only')

    expect(result).to eq(messages_imported: 1, contacts_touched: 1)
    expect(imported_message).to be_present
    expect(imported_message.conversation.contact_inbox.source_id).to eq('143907392331785@lid')
    expect(imported_message.conversation.contact.phone_number).to be_nil
  end

  it 'reuses the same conversation when history first arrives as LID and later as canonical phone jid' do
    described_class.new(
      channel: channel,
      records: [
        {
          key: {
            id: 'history-msg-lid-first',
            remoteJid: '143907392331785@lid',
            remoteLid: '143907392331785@lid',
            fromMe: false
          },
          pushName: 'Alice',
          messageTimestamp: 2.hours.ago.to_i,
          message: {
            conversation: 'First via LID'
          }
        },
        {
          key: {
            id: 'history-msg-pn-second',
            remoteJid: '15551234567@s.whatsapp.net',
            remoteLid: '143907392331785@lid',
            fromMe: false
          },
          pushName: 'Alice',
          messageTimestamp: 1.hour.ago.to_i,
          message: {
            conversation: 'Later via PN'
          }
        }
      ]
    ).perform

    conversations = channel.inbox.conversations.order(:id).to_a
    latest_message = channel.inbox.messages.find_by(source_id: 'history-msg-pn-second')

    expect(conversations.size).to eq(1)
    expect(latest_message).to be_present
    expect(latest_message.conversation_id).to eq(conversations.first.id)
    expect(conversations.first.contact.reload.phone_number).to eq('+15551234567')
    expect(conversations.first.last_activity_at.to_i).to eq(latest_message.created_at.to_i)
  end

  it 'keeps the conversation ordered by the newest imported message when older history chunks arrive later' do
    described_class.new(
      channel: channel,
      records: [
        {
          key: {
            id: 'history-msg-newer-first',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: false
          },
          pushName: 'Alice',
          messageTimestamp: 1.hour.ago.to_i,
          message: {
            conversation: 'Newer history chunk'
          }
        }
      ]
    ).perform

    conversation = channel.inbox.conversations.order(:id).last
    latest_activity_at = conversation.last_activity_at
    latest_contact_activity_at = conversation.contact.reload.last_activity_at

    described_class.new(
      channel: channel,
      records: [
        {
          key: {
            id: 'history-msg-older-later',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: false
          },
          pushName: 'Alice',
          messageTimestamp: 2.days.ago.to_i,
          message: {
            conversation: 'Older history chunk that arrived later'
          }
        }
      ]
    ).perform

    expect(conversation.reload.last_activity_at.to_i).to eq(latest_activity_at.to_i)
    expect(conversation.contact.reload.last_activity_at.to_i).to eq(latest_contact_activity_at.to_i)
  end
end
