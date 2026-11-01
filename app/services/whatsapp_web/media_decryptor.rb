class WhatsappWeb::MediaDecryptor
  class DecryptionError < StandardError; end

  Result = Struct.new(:plaintext, :content_type, :filename, :extension, :file_type, :hkdf_info, :byte_size, :sha256_hex, keyword_init: true)

  HKDF_INFO_BY_KIND = {
    'image' => 'WhatsApp Image Keys', 'sticker' => 'WhatsApp Image Keys',
    'video' => 'WhatsApp Video Keys', 'audio' => 'WhatsApp Audio Keys',
    'document' => 'WhatsApp Document Keys'
  }.freeze

  MIN_ENCRYPTED_BYTES = 26
  MAC_LENGTH = 10
  KEY_LENGTH = 32
  HKDF_EXPANDED_LENGTH = 112

  class << self
    def encrypted_whatsapp_url?(url) = WhatsappWeb::MediaEncryptionMetadata.encrypted_whatsapp_url?(url)
    def encrypted_media_payload?(options = {}) = WhatsappWeb::MediaEncryptionMetadata.encrypted_media_payload?(options)
    def resolve_media_url(raw_url, direct_path = nil) = WhatsappWeb::MediaEncryptionMetadata.resolve_media_url(raw_url, direct_path)
    def merge_encryption_metadata(primary, secondary) = WhatsappWeb::MediaEncryptionMetadata.merge_encryption_metadata(primary, secondary)
    def decode_binary_field(value, field_name: 'binary_field') = WhatsappWeb::MediaBinaryCodec.decode_binary_field(value, field_name: field_name)
    def parse_file_length(value) = WhatsappWeb::MediaBinaryCodec.parse_file_length(value)
    def validate_whatsapp_cdn_url!(url) = WhatsappWeb::EncryptedCdnDownloader.validate_whatsapp_cdn_url!(url)
    def download_encrypted_media_bytes(url) = WhatsappWeb::EncryptedCdnDownloader.download_encrypted_media_bytes(url)

    def extract_encryption_metadata(record: {}, attachment_payload: {})
      WhatsappWeb::MediaEncryptionMetadata.extract_encryption_metadata(record: record, attachment_payload: attachment_payload)
    end

    def resolve_hkdf_info(media_kind: nil, mime_type: nil)
      canonical_kind = WhatsappWeb::MediaMimeNormalizer.canonical_media_kind(media_kind)
      canonical_kind.present? ? HKDF_INFO_BY_KIND.fetch(canonical_kind) : resolve_hkdf_info_from_mime(mime_type)
    end

    def decrypt_bytes(encrypted_bytes:, media_key:, metadata: {})
      enc = validate_encrypted_bytes!(encrypted_bytes)
      raw_key = validate_media_key!(media_key)
      meta = metadata.to_h.deep_symbolize_keys
      verify_sha256!(enc, meta_value(meta, %i[file_enc_sha256 fileEncSha256]), 'fileEncSha256')

      hkdf_info = resolve_hkdf_info(media_kind: meta[:media_kind], mime_type: meta_value(meta, %i[mime_type mimetype]))
      plaintext = perform_authenticated_decrypt(enc, raw_key, hkdf_info)
      verify_plaintext_integrity!(plaintext, meta)
      build_result(plaintext, meta, hkdf_info)
    end

    def decrypt_to_tempfile(encrypted_bytes:, media_key:, metadata: {})
      result = decrypt_bytes(encrypted_bytes: encrypted_bytes, media_key: media_key, metadata: metadata)
      tempfile = Tempfile.new(['whatsapp-web', ".#{result.extension}"])
      tempfile.binmode
      tempfile.write(result.plaintext)
      tempfile.rewind
      tempfile.define_singleton_method(:original_filename) { result.filename }
      tempfile.define_singleton_method(:content_type) { result.content_type }
      tempfile
    end

    def decrypt_remote_media(url:, media_key:, metadata: {})
      decrypt_to_tempfile(encrypted_bytes: download_encrypted_media_bytes(url), media_key: media_key, metadata: metadata)
    end

    private

    def meta_value(meta, keys) = WhatsappWeb::MediaEncryptionMetadata.first_present([meta], keys)

    def resolve_hkdf_info_from_mime(mime_type)
      base = WhatsappWeb::MediaMimeNormalizer.base_mime(mime_type)
      raise DecryptionError, 'Unable to determine WhatsApp HKDF media type' if base.blank?
      return 'WhatsApp Image Keys' if base.start_with?('image/')
      return 'WhatsApp Video Keys' if base.start_with?('video/')
      return 'WhatsApp Audio Keys' if base.start_with?('audio/')

      'WhatsApp Document Keys'
    end

    def validate_encrypted_bytes!(encrypted_bytes)
      raise DecryptionError, 'Encrypted payload is empty' if encrypted_bytes.nil?

      enc = encrypted_bytes.to_s.dup.force_encoding(Encoding::BINARY)
      return enc if enc.bytesize >= MIN_ENCRYPTED_BYTES && ((enc.bytesize - MAC_LENGTH) % 16).zero?

      raise DecryptionError, "Invalid encrypted media length: #{enc.bytesize}"
    end

    def validate_media_key!(media_key)
      raw_key = decode_binary_field(media_key, field_name: 'mediaKey')
      return raw_key if raw_key.present? && raw_key.bytesize == KEY_LENGTH

      raise DecryptionError, "Invalid mediaKey length: #{raw_key&.bytesize.inspect}"
    end

    def perform_authenticated_decrypt(enc, raw_key, hkdf_info)
      expanded = OpenSSL::KDF.hkdf(raw_key, salt: "\x00".b * 32, info: hkdf_info, length: HKDF_EXPANDED_LENGTH, hash: 'SHA256')
      init_vec = expanded.byteslice(0, 16)
      ciphertext = enc.byteslice(0, enc.bytesize - MAC_LENGTH)
      verify_mac!(expanded.byteslice(48, 32), init_vec, ciphertext, enc.byteslice(enc.bytesize - MAC_LENGTH, MAC_LENGTH))
      aes_cbc_decrypt(expanded.byteslice(16, 32), init_vec, ciphertext)
    end

    def verify_mac!(mac_key, init_vec, ciphertext, expected_mac)
      hmac = OpenSSL::HMAC.new(mac_key, 'SHA256')
      hmac.update(init_vec)
      hmac.update(ciphertext)
      computed_mac = hmac.digest.byteslice(0, MAC_LENGTH)
      return if OpenSSL.fixed_length_secure_compare(computed_mac, expected_mac)

      raise DecryptionError, 'WhatsApp media HMAC verification failed'
    end

    def aes_cbc_decrypt(cipher_key, init_vec, ciphertext)
      decipher = OpenSSL::Cipher.new('AES-256-CBC')
      decipher.decrypt
      decipher.key = cipher_key
      decipher.iv = init_vec
      (decipher.update(ciphertext) + decipher.final).force_encoding(Encoding::BINARY)
    rescue OpenSSL::Cipher::CipherError => e
      raise DecryptionError, "AES-256-CBC decryption failed: #{e.message}"
    end

    def verify_plaintext_integrity!(plaintext, meta)
      expected_sha_raw = meta_value(meta, %i[file_sha256 fileSha256])
      return verify_sha256!(plaintext, expected_sha_raw, 'fileSha256') if expected_sha_raw.present?

      expected_len = parse_file_length(meta_value(meta, %i[file_length fileLength]))
      return if expected_len.nil? || expected_len <= 0 || plaintext.bytesize == expected_len

      raise DecryptionError, "Decrypted byte length #{plaintext.bytesize} does not match expected #{expected_len}"
    end

    def verify_sha256!(bytes, expected_raw, field_name)
      return if expected_raw.blank?

      expected = decode_binary_field(expected_raw, field_name: field_name)
      raise DecryptionError, "Invalid #{field_name} length" unless expected.present? && expected.bytesize == KEY_LENGTH
      return if OpenSSL.fixed_length_secure_compare(OpenSSL::Digest::SHA256.digest(bytes), expected)

      raise DecryptionError, "#{field_name} mismatch"
    end

    def build_result(plaintext, meta, hkdf_info)
      raw_name = meta_value(meta, %i[filename file_name fileName])
      content_type = resolve_content_type(plaintext, meta_value(meta, %i[mime_type mimetype]), raw_name, meta[:media_kind])
      filename = WhatsappWeb::MediaMimeNormalizer.sanitize_filename(raw_name, mime_type: content_type, media_kind: meta[:media_kind])
      extension = WhatsappWeb::MediaMimeNormalizer.extension_for(mime_type: content_type, filename: filename, media_kind: meta[:media_kind])

      Result.new(
        plaintext: plaintext, content_type: content_type, filename: filename, extension: extension,
        file_type: WhatsappWeb::MediaMimeNormalizer.file_type_for(media_kind: meta[:media_kind], mime_type: content_type),
        hkdf_info: hkdf_info, byte_size: plaintext.bytesize, sha256_hex: OpenSSL::Digest::SHA256.hexdigest(plaintext)
      )
    end

    def resolve_content_type(plaintext, raw_mime, raw_name, media_kind)
      normalized = WhatsappWeb::MediaMimeNormalizer.normalize_mime_type(raw_mime, filename: raw_name, media_kind: media_kind)
      return normalized if WhatsappWeb::MediaMimeNormalizer.concrete_mime?(normalized)

      sniffed = Marcel::MimeType.for(StringIO.new(plaintext), name: WhatsappWeb::MediaMimeNormalizer.strip_enc_filename(raw_name))
      WhatsappWeb::MediaMimeNormalizer.concrete_mime?(sniffed) ? sniffed : normalized
    rescue StandardError
      normalized
    end
  end
end
