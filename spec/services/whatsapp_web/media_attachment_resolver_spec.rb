require 'rails_helper'

RSpec.describe WhatsappWeb::MediaAttachmentResolver do
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
  let(:provider_service) { instance_double(WhatsappWeb::Providers::EvolutionService) }

  before do
    allow(channel).to receive(:provider_service).and_return(provider_service)
  end

  def encrypt_whatsapp_bytes(plaintext, hkdf_info:)
    raw_key = Random.bytes(32)
    expanded = OpenSSL::KDF.hkdf(raw_key, salt: "\x00".b * 32, info: hkdf_info, length: 112, hash: 'SHA256')
    iv = expanded.byteslice(0, 16)
    cipher = OpenSSL::Cipher.new('AES-256-CBC')
    cipher.encrypt
    cipher.key = expanded.byteslice(16, 32)
    cipher.iv = iv
    ciphertext = cipher.update(plaintext) + cipher.final
    mac = OpenSSL::HMAC.digest('SHA256', expanded.byteslice(48, 32), iv + ciphertext).byteslice(0, 10)
    enc = ciphertext + mac
    {
      media_key: Base64.strict_encode64(raw_key),
      enc_bytes: enc,
      file_sha256: Base64.strict_encode64(OpenSSL::Digest::SHA256.digest(plaintext)),
      file_enc_sha256: Base64.strict_encode64(OpenSSL::Digest::SHA256.digest(enc))
    }
  end

  def tempfile_for_bytes(bytes, suffix: '.enc')
    tf = Tempfile.new(['wa-cdn', suffix])
    tf.binmode
    tf.write(bytes)
    tf.rewind
    tf
  end

  it 'prefers provider media over downloading encrypted mmg.whatsapp.net URLs directly' do
    expect(Down).not_to receive(:download)
    expect(provider_service).to receive(:fetch_message_media).and_return(
      base64: Base64.strict_encode64('decrypted-pdf-bytes'),
      fileName: 'invoice.pdf.enc',
      mimetype: 'application/pdf'
    )

    record = {
      key: { id: 'MSG-RES-1', remoteJid: '15551234567@s.whatsapp.net', fromMe: false },
      message: { documentMessage: { url: 'https://mmg.whatsapp.net/v/t62/invoice.enc', mimetype: 'application/pdf' } }
    }
    result = described_class.new(channel: channel, record: record, source_id: 'MSG-RES-1').resolve(
      media_kind: 'document',
      mediaUrl: 'https://mmg.whatsapp.net/v/t62/invoice.enc',
      mimetype: 'application/pdf'
    )

    expect(result.pending_backfill).to be(false)
    expect(result.file).to be_present
    expect(result.file.original_filename).to eq('invoice.pdf')
    expect(result.file.content_type).to eq('application/pdf')
    expect(File.binread(result.file.path)).to eq('decrypted-pdf-bytes')
  ensure
    result&.file&.close!
  end

  it 'falls back to native Ruby E2EE decryption using refetched @lid record metadata when provider media fails' do
    plaintext = '%PDF-1.7-decrypted-via-ruby'.b
    fixture = encrypt_whatsapp_bytes(plaintext, hkdf_info: 'WhatsApp Document Keys')
    cdn_url = 'https://mmg.whatsapp.net/v/t62.7119-24/998877.enc?ccb=11-4'

    allow(provider_service).to receive(:fetch_message_media).and_raise(StandardError, 'Evolution 400 Bad Request')
    expect(provider_service).to receive(:fetch_message_by_source_id).once.and_return(
      'key' => { 'id' => 'MSG-LID-ENC-1', 'remoteJid' => '2455667788@lid', 'fromMe' => false },
      'message' => {
        'documentMessage' => {
          'url' => cdn_url,
          'mediaKey' => fixture[:media_key],
          'fileSha256' => fixture[:file_sha256],
          'fileEncSha256' => fixture[:file_enc_sha256],
          'fileName' => 'statement.pdf.enc',
          'mimetype' => 'application/pdf'
        }
      }
    )
    expect(Down).to receive(:download).with(cdn_url).and_return(tempfile_for_bytes(fixture[:enc_bytes]))

    initial_record = {
      key: { id: 'MSG-LID-ENC-1', remoteJid: '15551234567@s.whatsapp.net', fromMe: false },
      message: { documentMessage: { fileName: 'statement.pdf.enc', mimetype: 'application/pdf' } }
    }
    result = described_class.new(channel: channel, record: initial_record, source_id: 'MSG-LID-ENC-1').resolve(
      media_kind: 'document',
      fileName: 'statement.pdf.enc',
      mimetype: 'application/pdf'
    )

    expect(result.pending_backfill).to be(false)
    expect(result.file.original_filename).to eq('statement.pdf')
    expect(result.file.content_type).to eq('application/pdf')
    expect(File.binread(result.file.path)).to eq(plaintext)
  ensure
    result&.file&.close!
  end

  it 'never attaches raw .enc bytes and marks pending_backfill when HMAC verification fails' do
    fixture = encrypt_whatsapp_bytes('secret-image'.b, hkdf_info: 'WhatsApp Image Keys')
    bad_enc = fixture[:enc_bytes].byteslice(0, fixture[:enc_bytes].bytesize - 1) + "\x00".b
    cdn_url = 'https://mmg.whatsapp.net/v/t62.7118-24/corrupt.enc'

    allow(provider_service).to receive(:fetch_message_media).and_return(unavailable: true)
    expect(Down).to receive(:download).with(cdn_url).and_return(tempfile_for_bytes(bad_enc))

    record = {
      key: { id: 'MSG-BAD-MAC', remoteJid: '15551234567@s.whatsapp.net', fromMe: false },
      message: { imageMessage: { url: cdn_url, mediaKey: fixture[:media_key], mimetype: 'image/jpeg' } }
    }
    result = described_class.new(channel: channel, record: record, source_id: 'MSG-BAD-MAC').resolve(
      media_kind: 'image',
      mediaUrl: cdn_url,
      mediaKey: fixture[:media_key],
      mimetype: 'image/jpeg'
    )

    expect(result.file).to be_nil
    expect(result.pending_backfill).to be(true)
  end

  it 'still downloads genuinely unencrypted external URLs when provider media is absent' do
    plain_url = 'https://cdn.example.com/public/welcome.png'
    plain_tf = tempfile_for_bytes('plain-png-bytes', suffix: '.png')

    allow(provider_service).to receive(:fetch_message_media).and_return(nil)
    allow(provider_service).to receive(:fetch_message_by_source_id).and_return(nil)
    expect(Down).to receive(:download).with(plain_url).and_return(plain_tf)

    record = {
      key: { id: 'MSG-PLAIN-1', remoteJid: '15551234567@s.whatsapp.net', fromMe: false },
      message: { imageMessage: { url: plain_url, mimetype: 'image/png' } }
    }
    result = described_class.new(channel: channel, record: record, source_id: 'MSG-PLAIN-1').resolve(
      media_kind: 'image',
      mediaUrl: plain_url,
      mimetype: 'image/png'
    )

    expect(result.pending_backfill).to be(false)
    expect(result.file).to eq(plain_tf)
  ensure
    plain_tf&.close!
  end
end
