require 'rails_helper'

RSpec.describe WhatsappWeb::MediaDecryptor do
  def build_encrypted_fixture(plaintext, hkdf_info:, raw_key: Random.bytes(32))
    expanded = OpenSSL::KDF.hkdf(raw_key, salt: "\x00".b * 32, info: hkdf_info, length: 112, hash: 'SHA256')
    iv = expanded.byteslice(0, 16)
    cipher = OpenSSL::Cipher.new('AES-256-CBC')
    cipher.encrypt
    cipher.key = expanded.byteslice(16, 32)
    cipher.iv = iv
    ciphertext = cipher.update(plaintext) + cipher.final
    mac = OpenSSL::HMAC.digest('SHA256', expanded.byteslice(48, 32), iv + ciphertext).byteslice(0, 10)
    enc_bytes = ciphertext + mac

    {
      raw_key: raw_key,
      media_key: Base64.strict_encode64(raw_key),
      enc_bytes: enc_bytes,
      file_sha256: Base64.strict_encode64(OpenSSL::Digest::SHA256.digest(plaintext)),
      file_enc_sha256: Base64.strict_encode64(OpenSSL::Digest::SHA256.digest(enc_bytes)),
      file_length: plaintext.bytesize
    }
  end

  describe '.encrypted_whatsapp_url? and .encrypted_media_payload?' do
    it 'identifies WhatsApp encrypted CDN URLs and .enc payloads while allowing plain external URLs' do
      expect(described_class.encrypted_whatsapp_url?('https://mmg.whatsapp.net/v/t62.7118-24/3089.enc?ccb=11-4')).to be(true)
      expect(described_class.encrypted_whatsapp_url?('https://mmg.whatsapp.net/d/f/opaque-media-token')).to be(true)
      expect(described_class.encrypted_whatsapp_url?('https://cdn.whatsapp.net/media/item.enc?token=1')).to be(true)
      expect(described_class.encrypted_whatsapp_url?('https://cdn.example.com/public/photo.jpg')).to be(false)
      expect(described_class.encrypted_media_payload?(url: 'https://cdn.example.com/blob', media_key: 'abc')).to be(true)
      expect(described_class.encrypted_media_payload?(url: 'https://cdn.example.com/photo.jpg')).to be(false)
    end
  end

  describe '.validate_whatsapp_cdn_url! and .download_encrypted_media_bytes' do
    it 'rejects http://, userinfo, placeholder web.whatsapp.net, and non-whatsapp.net hosts before Down.download' do
      expect(Down).not_to receive(:download)

      [
        'http://mmg.whatsapp.net/v/t62.7118-24/file.enc',
        'https://user:pass@mmg.whatsapp.net/v/t62.7118-24/file.enc',
        'https://evil.example.com/v/t62.7118-24/file.enc',
        'https://mmg.whatsapp.net.evil.com/file.enc',
        'https://web.whatsapp.net/v/t62.7118-24/file.enc'
      ].each do |unsafe_url|
        expect { described_class.download_encrypted_media_bytes(unsafe_url) }
          .to raise_error(described_class::DecryptionError)
      end
    end

    it 'rejects private, loopback, metadata link-local, and IPv4-mapped loopback IPs before Down.download' do
      expect(Down).not_to receive(:download)
      cdn_url = 'https://mmg.whatsapp.net/v/t62.7118-24/ssrf.enc'

      ['127.0.0.1', '169.254.169.254', '10.0.0.1', '192.168.1.10', '::1', '::ffff:127.0.0.1'].each do |blocked_ip|
        allow(Resolv).to receive(:getaddresses).with('mmg.whatsapp.net').and_return([blocked_ip])

        expect { described_class.download_encrypted_media_bytes(cdn_url) }
          .to raise_error(described_class::DecryptionError, /Blocked non-public WhatsApp CDN IP/)
      end
    end

    it 'enforces max_redirects: 0, max_size, and timeouts when downloading from a public WhatsApp CDN IP' do
      cdn_url = 'https://mmg.whatsapp.net/v/t62.7118-24/valid.enc'
      tf = Tempfile.new(['wa-cdn-dl', '.enc']).tap do |file|
        file.binmode
        file.write('encrypted-payload-bytes')
        file.rewind
      end

      allow(Resolv).to receive(:getaddresses).with('mmg.whatsapp.net').and_return(['157.240.1.53'])
      expect(Down).to receive(:download).with(
        cdn_url,
        hash_including(max_redirects: 0, open_timeout: 10, read_timeout: 30, max_size: a_value >= 100.megabytes)
      ).and_return(tf)

      expect(described_class.download_encrypted_media_bytes(cdn_url)).to eq('encrypted-payload-bytes')
    end
  end

  describe '.extract_encryption_metadata and dotted document titles' do
    it 'synthesizes https://mmg.whatsapp.net<directPath> when url is blank or web.whatsapp.net' do
      direct_path = '/v/t62.7119-24/35112233_998877.enc?ccb=11-4&oh=abc'
      blank_url_record = { message: { documentMessage: { directPath: direct_path, mediaKey: 'key1' } } }
      placeholder_record = {
        message: {
          documentMessage: {
            url: 'https://web.whatsapp.net',
            directPath: direct_path,
            mediaKey: 'key2'
          }
        }
      }

      expect(described_class.extract_encryption_metadata(record: blank_url_record)[:url])
        .to eq("https://mmg.whatsapp.net#{direct_path}")
      expect(described_class.extract_encryption_metadata(record: placeholder_record)[:url])
        .to eq("https://mmg.whatsapp.net#{direct_path}")
    end

    it 'appends real .pdf extension to dotted document titles without treating trailing year digits as extension' do
      plaintext = '%PDF-1.7-dated-report'.b
      fixture = build_encrypted_fixture(plaintext, hkdf_info: 'WhatsApp Document Keys')

      result = described_class.decrypt_bytes(
        encrypted_bytes: fixture[:enc_bytes],
        media_key: fixture[:media_key],
        metadata: {
          media_kind: 'documentMessage',
          mime_type: 'application/pdf',
          filename: 'Отчет 28.10.2026',
          file_sha256: fixture[:file_sha256]
        }
      )

      expect(result.filename).to eq('Отчет 28.10.2026.pdf')
      expect(result.extension).to eq('pdf')
      expect(result.content_type).to eq('application/pdf')
    end
  end

  describe '.decrypt_bytes' do
    it 'decrypts an xlsx document and strips .enc from filename and extension' do
      plaintext = "PK\x03\x04fake-xlsx-workbook-bytes".b
      fixture = build_encrypted_fixture(plaintext, hkdf_info: 'WhatsApp Document Keys')
      xlsx_mime = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'

      result = described_class.decrypt_bytes(
        encrypted_bytes: fixture[:enc_bytes],
        media_key: fixture[:media_key],
        metadata: {
          media_kind: 'documentMessage',
          mime_type: xlsx_mime,
          filename: 'report.xlsx.enc',
          file_sha256: fixture[:file_sha256],
          file_enc_sha256: fixture[:file_enc_sha256],
          file_length: fixture[:file_length]
        }
      )

      expect(result.plaintext).to eq(plaintext)
      expect(result.filename).to eq('report.xlsx')
      expect(result.extension).to eq('xlsx')
      expect(result.content_type).to eq(xlsx_mime)
      expect(result.file_type).to eq('file')
    end

    it 'prioritizes WhatsApp message node type over mimetype for HKDF when a video is sent as a document' do
      plaintext = "\x00\x00\x00\x18ftypmp42video-sent-as-document".b
      fixture = build_encrypted_fixture(plaintext, hkdf_info: 'WhatsApp Document Keys')

      result = described_class.decrypt_bytes(
        encrypted_bytes: fixture[:enc_bytes],
        media_key: fixture[:media_key],
        metadata: {
          media_kind: 'documentMessage',
          mime_type: 'video/mp4',
          filename: 'raw_capture.mp4.enc',
          file_sha256: fixture[:file_sha256]
        }
      )

      expect(result.hkdf_info).to eq('WhatsApp Document Keys')
      expect(result.plaintext).to eq(plaintext)
      expect(result.filename).to eq('raw_capture.mp4')
      expect(result.extension).to eq('mp4')
      expect(result.file_type).to eq('file')
    end

    it 'normalizes opus voice-note MIME parameters to audio/ogg with .ogg extension' do
      plaintext = "OggS\x00\x02opus-voice-note-payload".b
      fixture = build_encrypted_fixture(plaintext, hkdf_info: 'WhatsApp Audio Keys')

      result = described_class.decrypt_bytes(
        encrypted_bytes: fixture[:enc_bytes],
        media_key: fixture[:media_key],
        metadata: {
          media_kind: 'audioMessage',
          mime_type: 'audio/ogg; codecs=opus'
        }
      )

      expect(result.plaintext).to eq(plaintext)
      expect(result.content_type).to eq('audio/ogg')
      expect(result.extension).to eq('ogg')
      expect(result.filename).to end_with('.ogg')
      expect(result.file_type).to eq('audio')
    end

    it 'accepts Buffer hashes, byte arrays, indexed hashes, URL-safe unpadded Base64, and Long fileLength' do
      plaintext = "\x89PNG\r\n\x1a\nsample-png-bytes".b
      raw_key = ("\xFB\xEF" * 16).b
      fixture = build_encrypted_fixture(plaintext, hkdf_info: 'WhatsApp Image Keys', raw_key: raw_key)
      key_bytes = raw_key.bytes
      sha_bytes = OpenSSL::Digest::SHA256.digest(plaintext).bytes

      urlsafe_unpadded_key = Base64.urlsafe_encode64(raw_key, padding: false)
      buffer_key = { 'type' => 'Buffer', 'data' => key_bytes }
      string_indexed_key = key_bytes.each_with_index.to_h { |byte, idx| [idx.to_s, byte] }
      symbol_indexed_sha = sha_bytes.each_with_index.to_h { |byte, idx| [idx.to_s.to_sym, byte] }
      long_length = { 'low' => plaintext.bytesize, 'high' => 0, 'unsigned' => true }

      [urlsafe_unpadded_key, buffer_key, key_bytes, string_indexed_key].each do |encoded_key|
        res = described_class.decrypt_bytes(
          encrypted_bytes: fixture[:enc_bytes],
          media_key: encoded_key,
          metadata: { media_kind: 'image', mime_type: 'image/png', file_sha256: symbol_indexed_sha, file_length: long_length }
        )
        expect(res.plaintext).to eq(plaintext)
      end
    end

    it 'parses 64-bit Protobuf Long fileLength with negative signed low int32' do
      long_val = { low: -1_294_967_296, high: 1, unsigned: true }
      expect(described_class.parse_file_length(long_val)).to eq(7_294_967_296)
      expect(described_class.parse_file_length('4096')).to eq(4096)
    end

    it 'raises DecryptionError on tampered HMAC, tampered SHA256, or invalid mediaKey length' do
      plaintext = 'confidential-clinical-document'.b
      fixture = build_encrypted_fixture(plaintext, hkdf_info: 'WhatsApp Document Keys')
      tampered_mac = fixture[:enc_bytes].byteslice(0, fixture[:enc_bytes].bytesize - 1) +
                     ((fixture[:enc_bytes].getbyte(-1) ^ 0xff).chr)

      expect do
        described_class.decrypt_bytes(
          encrypted_bytes: tampered_mac,
          media_key: fixture[:media_key],
          metadata: { media_kind: 'document', mime_type: 'text/plain' }
        )
      end.to raise_error(described_class::DecryptionError, /HMAC/)

      expect do
        described_class.decrypt_bytes(
          encrypted_bytes: fixture[:enc_bytes],
          media_key: Base64.strict_encode64('short-key'),
          metadata: { media_kind: 'document', mime_type: 'text/plain' }
        )
      end.to raise_error(described_class::DecryptionError, /mediaKey/)

      expect do
        described_class.decrypt_bytes(
          encrypted_bytes: fixture[:enc_bytes],
          media_key: fixture[:media_key],
          metadata: { media_kind: 'document', mime_type: 'text/plain', file_sha256: Base64.strict_encode64('0' * 32) }
        )
      end.to raise_error(described_class::DecryptionError, /fileSha256/)
    end
  end
end
