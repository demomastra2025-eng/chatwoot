require 'ipaddr'
require 'resolv'

module WhatsappWeb::EncryptedCdnDownloader
  OPEN_TIMEOUT_SECONDS = 10
  READ_TIMEOUT_SECONDS = 30
  MIN_MAX_DOWNLOAD_MB = 100
  ENCRYPTION_OVERHEAD_BYTES = 64

  PRIVATE_NETWORKS = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
    192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24
    203.0.113.0/24 224.0.0.0/4 240.0.0.0/4 ::/128 ::1/128 fc00::/7 fe80::/10
  ].map { |cidr| IPAddr.new(cidr) }.freeze

  module_function

  def download_encrypted_media_bytes(url)
    validated_url = validate_whatsapp_cdn_url!(url)
    downloaded = Down.download(
      validated_url,
      max_redirects: 0,
      max_size: max_encrypted_download_bytes,
      open_timeout: OPEN_TIMEOUT_SECONDS,
      read_timeout: READ_TIMEOUT_SECONDS
    )
    File.binread(downloaded.path)
  ensure
    downloaded.close! if downloaded.respond_to?(:close!)
  end

  def validate_whatsapp_cdn_url!(url)
    uri = parse_https_uri!(url)
    host = uri.host.to_s.downcase
    raise WhatsappWeb::MediaDecryptor::DecryptionError, "Disallowed WhatsApp CDN host: #{host.inspect}" unless allowed_whatsapp_cdn_host?(host)

    verify_public_host_ips!(host)
    uri.to_s
  end

  def parse_https_uri!(url)
    raw = url.to_s.strip
    raise WhatsappWeb::MediaDecryptor::DecryptionError, 'Encrypted media URL is blank' if raw.blank?

    uri = URI.parse(raw)
    raise WhatsappWeb::MediaDecryptor::DecryptionError, 'WhatsApp CDN URL must use HTTPS' unless uri.is_a?(URI::HTTPS)
    raise WhatsappWeb::MediaDecryptor::DecryptionError, 'WhatsApp CDN URL userinfo is not allowed' if uri.userinfo.present?

    uri
  rescue URI::InvalidURIError => e
    raise WhatsappWeb::MediaDecryptor::DecryptionError, "Invalid WhatsApp CDN URL: #{e.message}"
  end

  def allowed_whatsapp_cdn_host?(host)
    return false if host.blank? || host == 'web.whatsapp.net'

    host == 'whatsapp.net' || host.end_with?('.whatsapp.net')
  end

  def verify_public_host_ips!(host)
    addresses = Resolv.getaddresses(host)
    raise WhatsappWeb::MediaDecryptor::DecryptionError, "Could not resolve WhatsApp CDN host: #{host}" if addresses.blank?

    addresses.each { |address| verify_public_ip!(address) }
  end

  def verify_public_ip!(address)
    ip = IPAddr.new(address.to_s)
    normalized_ip = ip.ipv4_mapped? ? ip.native : ip
    return unless PRIVATE_NETWORKS.any? { |network| network.include?(normalized_ip) }

    raise WhatsappWeb::MediaDecryptor::DecryptionError, "Blocked non-public WhatsApp CDN IP: #{address}"
  rescue IPAddr::InvalidAddressError => e
    raise WhatsappWeb::MediaDecryptor::DecryptionError, "Invalid resolved IP #{address.inspect}: #{e.message}"
  end

  def max_encrypted_download_bytes
    configured_mb = GlobalConfigService.load('MAXIMUM_FILE_UPLOAD_SIZE', 40).to_i
    [configured_mb, MIN_MAX_DOWNLOAD_MB].max.megabytes + ENCRYPTION_OVERHEAD_BYTES
  end
end
