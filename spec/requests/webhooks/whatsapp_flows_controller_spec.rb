require 'rails_helper'

RSpec.describe 'Webhooks::WhatsappFlowsController', type: :request do
  let(:account) { create(:account, limits: { non_web_inboxes: 10 }) }
  let(:app_secret) { 'meta_test_app_secret_987654321' }
  let(:keypair) { Whatsapp::Flows::CryptoService.generate_keypair }
  let(:endpoint_secret) { Whatsapp::Flows::TokenService.generate_endpoint_secret }
  let(:channel) do
    record = create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
    record.update!(
      provider_config: record.provider_config.merge(
        'app_secret' => app_secret,
        'whatsapp_flows' => {
          'endpoint_secret' => endpoint_secret,
          'public_key_pem' => keypair[:public_key_pem],
          'encrypted_private_key' => Whatsapp::Flows::CryptoService.encrypt_private_key(keypair[:private_key_pem]),
          'encryption_status' => 'configured'
        }
      )
    )
    record
  end
  let(:endpoint_token) { Whatsapp::Flows::TokenService.build_endpoint_token(channel) }

  def encrypt_meta_body(payload, aes_key: OpenSSL::Random.random_bytes(16), request_iv: OpenSSL::Random.random_bytes(12))
    public_key = OpenSSL::PKey::RSA.new(keypair[:public_key_pem])
    encrypted_aes_key = public_key.encrypt(
      aes_key, rsa_padding_mode: 'oaep', rsa_oaep_md: 'sha256', rsa_mgf1_md: 'sha256'
    )
    ciphertext, tag = encrypt_aes_gcm(payload.to_json, aes_key, request_iv)

    {
      encrypted_aes_key: Base64.strict_encode64(encrypted_aes_key),
      encrypted_flow_data: Base64.strict_encode64(ciphertext + tag),
      initial_vector: Base64.strict_encode64(request_iv)
    }.to_json
  end

  def encrypt_aes_gcm(plaintext, aes_key, request_iv)
    cipher = OpenSSL::Cipher.new('aes-128-gcm')
    cipher.encrypt
    cipher.key = aes_key
    cipher.iv = request_iv
    cipher.auth_data = ''
    [cipher.update(plaintext) + cipher.final, cipher.auth_tag(16)]
  end

  def decrypt_meta_response(encoded_body, aes_key:, request_iv:)
    raw = Base64.strict_decode64(encoded_body)
    ciphertext = raw.byteslice(0, raw.bytesize - 16)
    auth_tag = raw.byteslice(raw.bytesize - 16, 16)
    flipped_iv = request_iv.bytes.map { |b| b ^ 0xFF }.pack('C*')

    cipher = OpenSSL::Cipher.new('aes-128-gcm')
    cipher.decrypt
    cipher.key = aes_key
    cipher.iv = flipped_iv
    cipher.auth_tag = auth_tag
    cipher.auth_data = ''
    JSON.parse(cipher.update(ciphertext) + cipher.final)
  end

  def signature_header(raw_body, secret = app_secret)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, raw_body)}"
  end

  it 'processes encrypted ping requests and returns 200 text/plain encrypted responses' do
    aes_key = OpenSSL::Random.random_bytes(16)
    request_iv = OpenSSL::Random.random_bytes(12)
    raw_body = encrypt_meta_body({ version: '3.0', action: 'ping' }, aes_key: aes_key, request_iv: request_iv)

    post "/webhooks/whatsapp/flows/#{endpoint_token}",
         params: raw_body,
         headers: {
           'CONTENT_TYPE' => 'application/json',
           'HTTP_X_HUB_SIGNATURE_256' => signature_header(raw_body)
         }

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('text/plain')
    expect(decrypt_meta_response(response.body, aes_key: aes_key, request_iv: request_iv)).to eq(
      'data' => { 'status' => 'active' }
    )
  end

  it 'returns 401 Unauthorized when X-Hub-Signature-256 is missing or invalid' do
    raw_body = encrypt_meta_body({ version: '3.0', action: 'ping' })

    post "/webhooks/whatsapp/flows/#{endpoint_token}",
         params: raw_body,
         headers: {
           'CONTENT_TYPE' => 'application/json',
           'HTTP_X_HUB_SIGNATURE_256' => signature_header(raw_body, 'wrong_secret')
         }

    expect(response).to have_http_status(:unauthorized)
  end

  it 'returns 404 Not Found when endpoint_token does not match any channel' do
    raw_body = encrypt_meta_body({ version: '3.0', action: 'ping' })

    post '/webhooks/whatsapp/flows/ch_999999_unknownsecretvalue123456',
         params: raw_body,
         headers: {
           'CONTENT_TYPE' => 'application/json',
           'HTTP_X_HUB_SIGNATURE_256' => signature_header(raw_body)
         }

    expect(response).to have_http_status(:not_found)
  end

  it 'returns 421 Misdirected Request when payload decryption fails' do
    corrupted_body = {
      encrypted_aes_key: Base64.strict_encode64('bad-key-bytes'),
      encrypted_flow_data: Base64.strict_encode64('bad-flow-data-bytes-with-tag'),
      initial_vector: Base64.strict_encode64('123456789012')
    }.to_json

    post "/webhooks/whatsapp/flows/#{endpoint_token}",
         params: corrupted_body,
         headers: {
           'CONTENT_TYPE' => 'application/json',
           'HTTP_X_HUB_SIGNATURE_256' => signature_header(corrupted_body)
         }

    expect(response).to have_http_status(:misdirected_request)
  end
end
