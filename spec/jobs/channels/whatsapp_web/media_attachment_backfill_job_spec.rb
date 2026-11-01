require 'rails_helper'

RSpec.describe Channels::WhatsappWeb::MediaAttachmentBackfillJob do
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
  let(:contact) { create(:contact, account: channel.account, phone_number: '+15551234567') }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: channel.inbox, source_id: '15551234567') }
  let(:conversation) do
    create(:conversation, account: channel.account, inbox: channel.inbox, contact: contact, contact_inbox: contact_inbox)
  end
  let!(:message) do
    create(
      :message,
      account: channel.account,
      inbox: channel.inbox,
      conversation: conversation,
      message_type: :incoming,
      source_id: 'LIVE_MEDIA_BACKFILL_1',
      content: 'Photo pending media'
    )
  end

  it 'runs on the whatsappweb_history queue' do
    expect(described_class.queue_name).to eq('whatsappweb_history')
  end

  it 'retries when the backfill job runs before the message is committed' do
    expect do
      described_class.perform_now(
        channel.id,
        'NOT_COMMITTED_YET',
        {
          'key' => {
            'id' => 'NOT_COMMITTED_YET',
            'remoteJid' => '15551234567@s.whatsapp.net',
            'fromMe' => false
          },
          'message' => {
            'imageMessage' => {
              'caption' => 'Photo pending commit',
              'mimetype' => 'image/png',
              'fileName' => 'pending.png'
            }
          }
        },
        1
      )
    end.to have_enqueued_job(described_class).with(
      channel.id,
      'NOT_COMMITTED_YET',
      hash_including('key' => hash_including('id' => 'NOT_COMMITTED_YET')),
      2
    )
  end

  it 'attaches provider media to an existing live message without duplicating attachments' do
    provider_service = instance_double(WhatsappWeb::Providers::EvolutionService)
    expect(provider_service).to receive(:fetch_message_media).with(
      record: hash_including('key' => hash_including('id' => 'LIVE_MEDIA_BACKFILL_1'))
    ).and_return(
      {
        base64: Base64.strict_encode64('provider-image-bytes'),
        fileName: 'provider-image.png',
        mimetype: 'image/png'
      }
    )
    allow_any_instance_of(Channel::WhatsappWeb).to receive(:provider_service).and_return(provider_service)

    described_class.perform_now(
      channel.id,
      'LIVE_MEDIA_BACKFILL_1',
      {
        'key' => {
          'id' => 'LIVE_MEDIA_BACKFILL_1',
          'remoteJid' => '15551234567@s.whatsapp.net',
          'fromMe' => false
        },
        'message' => {
          'imageMessage' => {
            'caption' => 'Photo pending media',
            'mimetype' => 'image/png',
            'fileName' => 'original-image.png'
          }
        }
      },
      1
    )

    expect(message.reload.attachments.count).to eq(1)
    expect(message.attachments.first.file_type).to eq('image')
    expect(message.attachments.first.file.attached?).to be(true)

    described_class.perform_now(channel.id, 'LIVE_MEDIA_BACKFILL_1', {}, 1)

    expect(message.reload.attachments.count).to eq(1)
  end

  it 'refetches the provider message when the queued payload is incomplete' do
    provider_record = {
      key: {
        id: 'LIVE_MEDIA_BACKFILL_1',
        remoteJid: '15551234567@s.whatsapp.net',
        fromMe: false
      },
      message: {
        documentWithCaptionMessage: {
          message: {
            documentMessage: {
              caption: 'Document pending media',
              mimetype: 'application/pdf',
              fileName: 'contract.pdf'
            }
          }
        }
      }
    }
    provider_service = instance_double(WhatsappWeb::Providers::EvolutionService)
    expect(provider_service).to receive(:fetch_message_by_source_id).with(
      source_id: 'LIVE_MEDIA_BACKFILL_1',
      remote_jid: '15551234567@s.whatsapp.net',
      from_me: false
    ).and_return(provider_record)
    expect(provider_service).to receive(:fetch_message_media).with(
      record: hash_including(key: hash_including(id: 'LIVE_MEDIA_BACKFILL_1'))
    ).and_return(
      {
        base64: Base64.strict_encode64('pdf-bytes'),
        fileName: 'contract.pdf',
        mimetype: 'application/pdf'
      }
    )
    allow_any_instance_of(Channel::WhatsappWeb).to receive(:provider_service).and_return(provider_service)

    described_class.perform_now(
      channel.id,
      'LIVE_MEDIA_BACKFILL_1',
      {
        'key' => {
          'id' => 'LIVE_MEDIA_BACKFILL_1',
          'remoteJid' => '15551234567@s.whatsapp.net',
          'fromMe' => false
        }
      },
      1
    )

    expect(message.reload.attachments.count).to eq(1)
    expect(message.attachments.first.file_type).to eq('file')
  end

  it 'decrypts encrypted WhatsApp CDN media natively during backfill when provider media fetch fails' do
    plaintext = "OggS\x00\x02backfill-decrypted-voice".b
    raw_key = Random.bytes(32)
    expanded = OpenSSL::KDF.hkdf(raw_key, salt: "\x00".b * 32, info: 'WhatsApp Audio Keys', length: 112, hash: 'SHA256')
    cipher = OpenSSL::Cipher.new('AES-256-CBC').tap do |c|
      c.encrypt
      c.key = expanded.byteslice(16, 32)
      c.iv = expanded.byteslice(0, 16)
    end
    ciphertext = cipher.update(plaintext) + cipher.final
    mac = OpenSSL::HMAC.digest('SHA256', expanded.byteslice(48, 32), expanded.byteslice(0, 16) + ciphertext).byteslice(0, 10)
    enc_tf = Tempfile.new(['wa-backfill', '.enc']).tap do |tf|
      tf.binmode
      tf.write(ciphertext + mac)
      tf.rewind
    end
    cdn_url = 'https://mmg.whatsapp.net/v/t62.7117-24/voice.enc'

    provider_service = instance_double(WhatsappWeb::Providers::EvolutionService)
    allow(provider_service).to receive(:fetch_message_media).and_return(unavailable: true)
    allow(WhatsappWeb::Providers::EvolutionService).to receive(:new).and_return(provider_service)
    expect(Down).to receive(:download).with(cdn_url).and_return(enc_tf)

    described_class.perform_now(
      channel.id,
      'LIVE_MEDIA_BACKFILL_1',
      {
        'key' => { 'id' => 'LIVE_MEDIA_BACKFILL_1', 'remoteJid' => '15551234567@s.whatsapp.net', 'fromMe' => false },
        'message' => {
          'audioMessage' => {
            'url' => cdn_url,
            'mediaKey' => Base64.strict_encode64(raw_key),
            'mimetype' => 'audio/ogg; codecs=opus'
          }
        }
      },
      1
    )

    att = message.reload.attachments.first
    expect(att).to be_present
    expect(att.file_type).to eq('audio')
    expect(att.extension).to eq('ogg')
    expect(att.file.content_type).to eq('audio/ogg')
    expect(att.file.blob.open { |tf| File.binread(tf.path) }).to eq(plaintext)
  end
end
