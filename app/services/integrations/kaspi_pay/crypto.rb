# frozen_string_literal: true

module Integrations::KaspiPay::Crypto
  VTOKEN_SUITE = 'OCRA-1:HOTP-SHA256-6:QH64-T1M'
  EC_CURVE = 'prime256v1'

  module_function

  def generate_device_identity
    ec_key = OpenSSL::PKey::EC.generate(EC_CURVE)
    public_der = ec_key.public_to_der
    uncompressed_point = public_der.byteslice(-65, 65)
    raise ArgumentError, 'Invalid EC uncompressed point' unless uncompressed_point&.getbyte(0) == 0x04

    pk_b64 = Base64.strict_encode64(uncompressed_point)
    public_b64 = Base64.strict_encode64(public_der)
    {
      'device_id' => SecureRandom.uuid.upcase,
      'install_id' => SecureRandom.uuid.upcase,
      'pin_hash' => SecureRandom.hex(16),
      'ec_private_key' => Base64.strict_encode64(ec_key.private_to_der),
      'ec_public_key' => public_b64,
      'pk' => pk_b64,
      'pk_tag' => Digest::MD5.hexdigest(pk_b64),
      'x509' => public_b64
    }
  end

  def generate_ecdh_keypair
    ecdh_key = OpenSSL::PKey::EC.generate(EC_CURVE)
    {
      private_key_b64: Base64.strict_encode64(ecdh_key.private_to_der),
      public_x509_b64: Base64.strict_encode64(ecdh_key.public_to_der)
    }
  end

  def complete_ecdh(private_key_b64, server_x509_b64)
    private_key = OpenSSL::PKey.read(Base64.strict_decode64(private_key_b64))
    server_pub = OpenSSL::PKey.read(Base64.strict_decode64(server_x509_b64))
    private_key.derive(server_pub)
  end

  def compute_token_sn_mac(token_sn, raw_secret, time_ms: (Time.now.to_f * 1000).to_i)
    return '000000' if raw_secret.blank?

    message = build_ocra_message(token_sn, time_ms)
    digest = OpenSSL::HMAC.digest('SHA256', raw_secret, message).bytes
    truncate_hotp(digest)
  end

  def build_ocra_message(token_sn, time_ms)
    time_hex = (time_ms / 30_000).to_s(16).rjust(16, '0')
    q_hex = (token_sn.presence || '00000000').to_s.b.unpack1('H*')[0, 64].ljust(256, '0')
    +"#{VTOKEN_SUITE}\x00".b << [q_hex].pack('H*') << [time_hex].pack('H*')
  end

  def truncate_hotp(digest)
    offset = digest[-1] & 0x0f
    bin_code =
      ((digest[offset] & 0x7f) << 24) |
      ((digest[offset + 1] & 0xff) << 16) |
      ((digest[offset + 2] & 0xff) << 8) |
      (digest[offset + 3] & 0xff)
    format('%06d', bin_code % 1_000_000)
  end

  def ec_sign(private_key_b64, data)
    private_key = OpenSSL::PKey.read(Base64.strict_decode64(private_key_b64))
    Base64.strict_encode64(private_key.sign('SHA256', data))
  end

  def sign_data_payload(private_key_b64, data_b64)
    ec_sign(private_key_b64, data_b64)
  end

  def compute_x_su(url)
    Digest::MD5.hexdigest(url.to_s.downcase)
  end

  def compute_x_sign(private_key_b64, url:, headers:, x_sh:, body: nil)
    sign_text = build_sign_lines(url, headers, x_sh).join("\n")
    sign_text = "#{sign_text}\n#{body}" if body.present?
    digest_bytes = OpenSSL::Digest::SHA256.digest(sign_text.encode('UTF-8'))
    ec_sign(private_key_b64, digest_bytes)
  end

  def build_sign_lines(url, headers, x_sh)
    downcased_lookup = headers.transform_keys { |k| k.to_s.downcase }
    x_sh.to_s.split(',').map do |name|
      next "url:#{url.to_s.downcase}" if name == 'url'

      key = name.downcase
      "#{key}:#{downcased_lookup[key] || ''}"
    end
  end
end
