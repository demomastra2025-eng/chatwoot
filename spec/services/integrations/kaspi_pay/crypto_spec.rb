# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::KaspiPay::Crypto do
  describe '.generate_device_identity' do
    it 'generates an isolated prime256v1 ECDSA identity with 65-byte uncompressed pk and MD5 pk_tag' do
      identity = described_class.generate_device_identity

      expect(identity['device_id']).to match(/\A[0-9A-F-]{36}\z/)
      expect(identity['install_id']).to match(/\A[0-9A-F-]{36}\z/)
      expect(identity['pin_hash']).to match(/\A[0-9a-f]{32}\z/)

      raw_pk = Base64.strict_decode64(identity['pk'])
      expect(raw_pk.bytesize).to eq(65)
      expect(raw_pk.getbyte(0)).to eq(0x04)
      expect(identity['pk_tag']).to eq(Digest::MD5.hexdigest(identity['pk']))
      expect(identity['x509']).to eq(identity['ec_public_key'])
    end
  end

  describe '.complete_ecdh' do
    it 'derives identical 32-byte shared secrets on client and server' do
      client = described_class.generate_ecdh_keypair
      server = described_class.generate_ecdh_keypair

      client_secret = described_class.complete_ecdh(client[:private_key_b64], server[:public_x509_b64])
      server_secret = described_class.complete_ecdh(server[:private_key_b64], client[:public_x509_b64])

      expect(client_secret.bytesize).to eq(32)
      expect(client_secret).to eq(server_secret)
    end
  end

  describe '.compute_token_sn_mac' do
    it 'computes deterministic 6-digit OCRA HOTP-SHA256-6 codes over 30-second steps' do
      secret = ('ab' * 16)
      t1 = 1_761_850_000_000
      code1 = described_class.compute_token_sn_mac('TOKENSN123', secret, time_ms: t1)
      code_same_window = described_class.compute_token_sn_mac('TOKENSN123', secret, time_ms: t1 + 1000)
      code_next_window = described_class.compute_token_sn_mac('TOKENSN123', secret, time_ms: t1 + 30_000)

      expect(code1).to match(/\A\d{6}\z/)
      expect(code_same_window).to eq(code1)
      expect(code_next_window).not_to eq(code1)
      expect(described_class.compute_token_sn_mac('TOKENSN123', '')).to eq('000000')
    end
  end

  describe '.compute_x_sign and .sign_data_payload' do
    it 'produces verifiable ECDSA signatures matching Kaspi X-Sign double-hash and data single-hash rules' do
      identity = described_class.generate_device_identity
      pub_key = OpenSSL::PKey.read(Base64.strict_decode64(identity['ec_public_key']))

      url = 'https://qrpay.kaspi.kz/v01/qr-token/create'
      headers = { 'X-Install-ID' => identity['install_id'], 'X-SV' => '2' }
      x_sh = 'url,X-Install-ID,X-SV'
      body = '{"PaymentAmount":5000}'

      x_sign = described_class.compute_x_sign(
        identity['ec_private_key'],
        url: url,
        headers: headers,
        x_sh: x_sh,
        body: body
      )

      expected_sign_text = "url:#{url.downcase}\nx-install-id:#{identity['install_id']}\nx-sv:2\n#{body}"
      first_digest = OpenSSL::Digest::SHA256.digest(expected_sign_text)
      expect(pub_key.verify('SHA256', Base64.strict_decode64(x_sign), first_digest)).to be(true)

      data_b64 = Base64.strict_encode64('{"hello":"kaspi"}')
      data_sig = described_class.sign_data_payload(identity['ec_private_key'], data_b64)
      expect(pub_key.verify('SHA256', Base64.strict_decode64(data_sig), data_b64)).to be(true)
    end
  end
end
