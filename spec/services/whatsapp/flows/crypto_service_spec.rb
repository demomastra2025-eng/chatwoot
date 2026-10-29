require 'rails_helper'

RSpec.describe Whatsapp::Flows::CryptoService do
  def build_meta_encrypted_request(
    public_key_pem:,
    payload:,
    aes_key: OpenSSL::Random.random_bytes(16),
    request_iv: OpenSSL::Random.random_bytes(12)
  )
    public_key = OpenSSL::PKey::RSA.new(public_key_pem)
    encrypted_aes_key = public_key.encrypt(
      aes_key, rsa_padding_mode: 'oaep', rsa_oaep_md: 'sha256', rsa_mgf1_md: 'sha256'
    )
    raw_json = payload.is_a?(String) ? payload : payload.to_json
    ciphertext, tag = encrypt_aes_gcm_payload(raw_json, aes_key, request_iv)

    {
      'encrypted_aes_key' => Base64.strict_encode64(encrypted_aes_key),
      'encrypted_flow_data' => Base64.strict_encode64(ciphertext + tag),
      'initial_vector' => Base64.strict_encode64(request_iv)
    }
  end

  def encrypt_aes_gcm_payload(raw_json, aes_key, request_iv)
    cipher = OpenSSL::Cipher.new("aes-#{aes_key.bytesize * 8}-gcm")
    cipher.encrypt
    cipher.key = aes_key
    cipher.iv = request_iv
    cipher.auth_data = ''
    [cipher.update(raw_json) + cipher.final, cipher.auth_tag(16)]
  end

  def decrypt_meta_response(encoded_response, aes_key:, request_iv:)
    raw = Base64.strict_decode64(encoded_response)
    ciphertext = raw.byteslice(0, raw.bytesize - 16)
    auth_tag = raw.byteslice(raw.bytesize - 16, 16)
    flipped_iv = request_iv.bytes.map { |byte| byte ^ 0xFF }.pack('C*')

    cipher = OpenSSL::Cipher.new("aes-#{aes_key.bytesize * 8}-gcm")
    cipher.decrypt
    cipher.key = aes_key
    cipher.iv = flipped_iv
    cipher.auth_tag = auth_tag
    cipher.auth_data = ''
    JSON.parse(cipher.update(ciphertext) + cipher.final)
  end

  describe '.generate_keypair and private key encryption at rest' do
    it 'generates a 2048-bit RSA keypair and roundtrips encrypted private key storage' do
      keypair = described_class.generate_keypair
      rsa = OpenSSL::PKey::RSA.new(keypair[:private_key_pem])

      expect(rsa).to be_private
      expect(rsa.n.num_bits).to eq(2048)
      expect(keypair[:public_key_pem]).to include('BEGIN PUBLIC KEY')

      encrypted_blob = described_class.encrypt_private_key(keypair[:private_key_pem])
      expect(encrypted_blob).not_to include('PRIVATE KEY')
      expect(described_class.decrypt_private_key(encrypted_blob)).to eq(keypair[:private_key_pem])
    end

    it 'raises ConfigurationError when encrypting a blank private key' do
      expect { described_class.encrypt_private_key('   ') }
        .to raise_error(described_class::ConfigurationError)
    end

    it 'raises DecryptionError when decrypting a missing or corrupted stored private key' do
      expect { described_class.decrypt_private_key('') }
        .to raise_error(described_class::DecryptionError)
      expect { described_class.decrypt_private_key('corrupted--cipher--blob') }
        .to raise_error(described_class::DecryptionError)
    end
  end

  describe '#decrypt_request and #encrypt_response' do
    let(:keypair) { described_class.generate_keypair }
    let(:service) { described_class.new(private_key_pem: keypair[:private_key_pem]) }

    it 'decrypts a Meta RSA-OAEP-SHA256 + AES-128-GCM request and encrypts response with flipped IV' do
      aes_key = OpenSSL::Random.random_bytes(16)
      request_iv = OpenSSL::Random.random_bytes(12)
      body = build_meta_encrypted_request(
        public_key_pem: keypair[:public_key_pem],
        payload: { version: '3.0', action: 'INIT', flow_token: 'olf1.sample.sig' },
        aes_key: aes_key,
        request_iv: request_iv
      )

      decrypted = service.decrypt_request(body)
      expect(decrypted[:payload]).to include('version' => '3.0', 'action' => 'INIT', 'flow_token' => 'olf1.sample.sig')
      expect(decrypted[:aes_key]).to eq(aes_key)
      expect(decrypted[:initial_vector]).to eq(request_iv)

      encoded_response = service.encrypt_response(
        { screen: 'BOOKING_STEP', data: { show_services: true } },
        aes_key: decrypted[:aes_key],
        initial_vector: decrypted[:initial_vector]
      )
      client_decrypted = decrypt_meta_response(encoded_response, aes_key: aes_key, request_iv: request_iv)
      expect(client_decrypted).to eq(
        'screen' => 'BOOKING_STEP',
        'data' => { 'show_services' => true }
      )
    end

    it 'raises DecryptionError when GCM auth tag is tampered' do
      body = build_meta_encrypted_request(
        public_key_pem: keypair[:public_key_pem],
        payload: { version: '3.0', action: 'ping' }
      )
      raw_data = Base64.strict_decode64(body['encrypted_flow_data']).dup
      raw_data.setbyte(-1, raw_data.getbyte(-1) ^ 0x01)
      body['encrypted_flow_data'] = Base64.strict_encode64(raw_data)

      expect { service.decrypt_request(body) }.to raise_error(described_class::DecryptionError)
    end

    it 'raises DecryptionError when encrypted with a different RSA public key' do
      other_keypair = described_class.generate_keypair
      body = build_meta_encrypted_request(
        public_key_pem: other_keypair[:public_key_pem],
        payload: { version: '3.0', action: 'ping' }
      )

      expect { service.decrypt_request(body) }.to raise_error(described_class::DecryptionError)
    end

    it 'raises DecryptionError when decrypted JSON is malformed or not an object' do
      malformed_body = build_meta_encrypted_request(
        public_key_pem: keypair[:public_key_pem],
        payload: '{broken-json'
      )
      array_body = build_meta_encrypted_request(
        public_key_pem: keypair[:public_key_pem],
        payload: '["not","an","object"]'
      )

      expect { service.decrypt_request(malformed_body) }.to raise_error(described_class::DecryptionError)
      expect { service.decrypt_request(array_body) }.to raise_error(described_class::DecryptionError)
    end
  end
end
