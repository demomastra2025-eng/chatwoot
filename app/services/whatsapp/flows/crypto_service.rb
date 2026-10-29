# frozen_string_literal: true

require 'openssl'
require 'base64'

class Whatsapp::Flows::CryptoService
  class DecryptionError < StandardError; end
  class ConfigurationError < StandardError; end

  RSA_KEY_BITS = 2048
  GCM_AUTH_TAG_BYTES = 16
  VALID_AES_KEY_BYTES = [16, 24, 32].freeze
  KEY_DERIVATION_SALT = 'whatsapp_flows_private_key_v1'
  RSA_OAEP_OPTIONS = {
    rsa_padding_mode: 'oaep',
    rsa_oaep_md: 'sha256',
    rsa_mgf1_md: 'sha256'
  }.freeze

  class << self
    def generate_keypair
      rsa = OpenSSL::PKey::RSA.generate(RSA_KEY_BITS)
      {
        public_key_pem: rsa.public_key.to_pem,
        private_key_pem: rsa.to_pem
      }
    end

    def encrypt_private_key(private_key_pem)
      raise ConfigurationError, 'Private key PEM cannot be blank' if private_key_pem.to_s.strip.blank?

      message_encryptor.encrypt_and_sign(private_key_pem.to_s)
    end

    def decrypt_private_key(encrypted_blob)
      raise DecryptionError, 'Encrypted private key is missing' if encrypted_blob.to_s.strip.blank?

      message_encryptor.decrypt_and_verify(encrypted_blob.to_s)
    rescue ActiveSupport::MessageEncryptor::InvalidMessage => e
      raise DecryptionError, "Stored Flow private key could not be decrypted: #{e.class}"
    end

    def for_channel(channel)
      encrypted = channel&.provider_config.to_h.dig('whatsapp_flows', 'encrypted_private_key')
      new(private_key_pem: decrypt_private_key(encrypted))
    end

    private

    def message_encryptor
      secret = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base)
                                          .generate_key(KEY_DERIVATION_SALT, 32)
      ActiveSupport::MessageEncryptor.new(secret, cipher: 'aes-256-gcm')
    end
  end

  def initialize(private_key_pem:)
    raise DecryptionError, 'Private key PEM is missing' if private_key_pem.to_s.strip.blank?

    @private_key = OpenSSL::PKey.read(private_key_pem.to_s)
    raise DecryptionError, 'Expected an RSA private key' unless @private_key.is_a?(OpenSSL::PKey::RSA) && @private_key.private?
  rescue OpenSSL::PKey::PKeyError => e
    raise DecryptionError, "Invalid RSA private key: #{e.message}"
  end

  def decrypt_request(body_params)
    params = body_params.to_h.with_indifferent_access
    encrypted_aes_key = decode_base64!(params[:encrypted_aes_key], 'encrypted_aes_key')
    encrypted_flow_data = decode_base64!(params[:encrypted_flow_data], 'encrypted_flow_data')
    initial_vector = decode_base64!(params[:initial_vector], 'initial_vector')

    aes_key = decrypt_aes_key(encrypted_aes_key)
    plaintext = decrypt_flow_payload(encrypted_flow_data, aes_key: aes_key, initial_vector: initial_vector)
    parsed = JSON.parse(plaintext.force_encoding(Encoding::UTF_8))
    raise DecryptionError, 'Decrypted Flow payload must be a JSON object' unless parsed.is_a?(Hash)

    {
      payload: parsed.with_indifferent_access,
      aes_key: aes_key,
      initial_vector: initial_vector
    }
  rescue JSON::ParserError => e
    raise DecryptionError, "Decrypted Flow JSON is malformed: #{e.message}"
  end

  def encrypt_response(response_payload, aes_key:, initial_vector:)
    validate_aes_key!(aes_key)
    raise DecryptionError, 'Initial vector cannot be empty' if initial_vector.to_s.b.empty?

    plaintext_json = response_payload.is_a?(String) ? response_payload : response_payload.to_json
    cipher = OpenSSL::Cipher.new("aes-#{aes_key.bytesize * 8}-gcm")
    cipher.encrypt
    cipher.key = aes_key
    cipher.iv = flip_initial_vector(initial_vector)
    cipher.auth_data = ''

    ciphertext = cipher.update(plaintext_json) + cipher.final
    Base64.strict_encode64(ciphertext + cipher.auth_tag(GCM_AUTH_TAG_BYTES))
  rescue OpenSSL::Cipher::CipherError => e
    raise DecryptionError, "Failed to encrypt Flow response: #{e.message}"
  end

  private

  def decode_base64!(raw_value, field_name)
    normalized = raw_value.to_s.gsub(/\s+/, '')
    raise DecryptionError, "Missing #{field_name}" if normalized.empty?

    decoded = Base64.strict_decode64(normalized)
    raise DecryptionError, "Decoded #{field_name} is empty" if decoded.empty?

    decoded
  rescue ArgumentError => e
    raise DecryptionError, "Invalid Base64 in #{field_name}: #{e.message}"
  end

  def decrypt_aes_key(encrypted_aes_key)
    aes_key = @private_key.decrypt(encrypted_aes_key, RSA_OAEP_OPTIONS)
    validate_aes_key!(aes_key)
    aes_key
  rescue OpenSSL::PKey::PKeyError => e
    raise DecryptionError, "RSA-OAEP key decryption failed: #{e.message}"
  end

  def validate_aes_key!(aes_key)
    return if aes_key.is_a?(String) && VALID_AES_KEY_BYTES.include?(aes_key.bytesize)

    raise DecryptionError, 'Unsupported AES key length'
  end

  def decrypt_flow_payload(encrypted_flow_data, aes_key:, initial_vector:)
    raise DecryptionError, 'Encrypted Flow data is shorter than GCM tag' if encrypted_flow_data.bytesize <= GCM_AUTH_TAG_BYTES
    raise DecryptionError, 'Initial vector cannot be empty' if initial_vector.bytesize.zero?

    body_length = encrypted_flow_data.bytesize - GCM_AUTH_TAG_BYTES
    cipher_body = encrypted_flow_data.byteslice(0, body_length)
    auth_tag = encrypted_flow_data.byteslice(body_length, GCM_AUTH_TAG_BYTES)

    cipher = OpenSSL::Cipher.new("aes-#{aes_key.bytesize * 8}-gcm")
    cipher.decrypt
    cipher.key = aes_key
    cipher.iv = initial_vector
    cipher.auth_tag = auth_tag
    cipher.auth_data = ''
    cipher.update(cipher_body) + cipher.final
  rescue OpenSSL::Cipher::CipherError => e
    raise DecryptionError, "AES-GCM decryption failed: #{e.message}"
  end

  def flip_initial_vector(initial_vector)
    initial_vector.bytes.map { |byte| byte ^ 0xFF }.pack('C*')
  end
end
