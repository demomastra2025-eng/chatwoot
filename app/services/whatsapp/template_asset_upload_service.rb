class Whatsapp::TemplateAssetUploadService
  MAX_DOWNLOAD_SIZE = Whatsapp::TemplateMediaValidator::MAX_FILE_SIZE
  PRIVATE_IP_RANGES = [
    IPAddr.new('127.0.0.0/8'),
    IPAddr.new('10.0.0.0/8'),
    IPAddr.new('172.16.0.0/12'),
    IPAddr.new('192.168.0.0/16'),
    IPAddr.new('169.254.0.0/16'),
    IPAddr.new('::1'),
    IPAddr.new('fc00::/7'),
    IPAddr.new('fe80::/10')
  ].freeze
  DISALLOWED_HOSTS = ['localhost', /\.local\z/i].freeze
  pattr_initialize [:whatsapp_channel!]

  def upload(url:, media_type:)
    validate_app_configuration!
    validated_url = validate_download_url!(url)

    file = Down::NetHttp.download(validated_url, max_size: MAX_DOWNLOAD_SIZE, max_redirects: 0)
    file_name = resolve_file_name(file, validated_url, media_type)
    content_type = validate_media!(file, file_name: file_name, media_type: media_type)

    upload_session_id = create_upload_session(
      file_name: file_name,
      file_length: file.size,
      content_type: content_type
    )

    upload_file(upload_session_id, file)
  ensure
    close_download(file)
  end

  def upload_blob(blob_signed_id:, media_type:)
    validate_app_configuration!
    blob = ActiveStorage::Blob.find_signed(blob_signed_id)
    raise ArgumentError, 'Uploaded media file is invalid or no longer available' if blob.blank?
    raise ArgumentError, 'Uploaded media file does not belong to this account' unless blob_account_id(blob) == whatsapp_channel.account_id

    Whatsapp::TemplateMediaValidator.validate_size!(blob.byte_size)

    blob.open do |file|
      file_name = blob.filename.to_s
      content_type = validate_media!(file, file_name: file_name, media_type: media_type, byte_size: blob.byte_size)

      upload_file_with_metadata(file, file_name: file_name, content_type: content_type)
    end
  end

  private

  def validate_app_configuration!
    return if app_id.present?

    raise ArgumentError, 'WHATSAPP_APP_ID is not configured'
  end

  def validate_media!(file, file_name:, media_type:, byte_size: file.size)
    Whatsapp::TemplateMediaValidator.validate!(
      io: file,
      file_name: file_name,
      media_type: media_type,
      byte_size: byte_size
    )
  end

  def validate_download_url!(url)
    uri = parse_download_uri!(url)
    validate_public_hostname!(uri.host.to_s)
    uri.to_s
  rescue URI::InvalidURIError
    raise ArgumentError, 'Sample media URL must be a valid URL'
  rescue Resolv::ResolvError, SocketError => e
    raise ArgumentError, "Sample media URL host could not be resolved: #{e.message}"
  end

  def parse_download_uri!(url)
    uri = URI.parse(url)
    raise ArgumentError, 'Sample media URL must start with http:// or https://' unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
    raise ArgumentError, 'Sample media URL must include a hostname' if uri.host.blank?

    uri
  end

  def validate_public_hostname!(hostname)
    raise ArgumentError, 'Sample media URL cannot use an IP address' if ip_literal?(hostname)
    raise ArgumentError, 'Sample media URL cannot use localhost or local hostnames' if disallowed_host?(hostname)

    validate_public_addresses!(Resolv.getaddresses(hostname).uniq)
  end

  def validate_public_addresses!(addresses)
    raise ArgumentError, 'Sample media URL host could not be resolved' if addresses.empty?
    raise ArgumentError, 'Sample media URL cannot resolve to a private IP address' if addresses.any? { |address| private_ip?(IPAddr.new(address)) }
  end

  def create_upload_session(file_name:, file_length:, content_type:)
    response = HTTParty.post(
      "#{api_base_path}/#{api_version}/#{app_id}/uploads",
      query: {
        file_name: file_name,
        file_length: file_length,
        file_type: content_type,
        access_token: access_token
      }.merge(graph_api_query)
    )

    parsed_response = parse_response(response, 'Failed to create WhatsApp upload session')
    parsed_response.fetch('id')
  end

  def upload_file_with_metadata(file, file_name:, content_type:)
    upload_session_id = create_upload_session(
      file_name: file_name,
      file_length: file.size,
      content_type: content_type
    )

    upload_file(upload_session_id, file)
  end

  def upload_file(upload_session_id, file)
    file.rewind if file.respond_to?(:rewind)
    response = HTTParty.post(
      "#{api_base_path}/#{api_version}/#{upload_session_id}",
      headers: {
        'Authorization' => "OAuth #{access_token}",
        'file_offset' => '0'
      },
      query: graph_api_query,
      body: file.read
    )

    parsed_response = parse_response(response, 'Failed to upload WhatsApp template sample media')
    parsed_response.fetch('h')
  end

  def resolve_file_name(file, url, media_type)
    basename = File.basename(Addressable::URI.parse(url).path.to_s)
    basename = file.original_filename if basename.blank? && file.respond_to?(:original_filename)
    basename = default_file_name(media_type) if basename.blank? || basename == '/'
    basename
  rescue Addressable::URI::InvalidURIError
    default_file_name(media_type)
  end

  def default_file_name(media_type)
    {
      'image' => 'template-image.jpg',
      'video' => 'template-video.mp4',
      'document' => 'template-document.pdf'
    }.fetch(media_type, 'template-media.bin')
  end

  def close_download(file)
    return if file.blank?

    file.close! if file.respond_to?(:close!)
    file.close if file.respond_to?(:close) && (!file.respond_to?(:closed?) || !file.closed?)
  rescue StandardError
    nil
  end

  def disallowed_host?(hostname)
    normalized_host = hostname.to_s.downcase

    DISALLOWED_HOSTS.any? do |pattern|
      pattern.is_a?(Regexp) ? normalized_host.match?(pattern) : normalized_host == pattern
    end
  end

  def ip_literal?(hostname)
    IPAddr.new(hostname)
    true
  rescue IPAddr::InvalidAddressError
    false
  end

  def private_ip?(ip_address)
    PRIVATE_IP_RANGES.any? { |range| range.include?(ip_address) }
  end

  def parse_response(response, error_message)
    return response.parsed_response if response.success?

    safe_body = Meta::CredentialDataSanitizer.sanitize(
      response.body.to_s.first(5000),
      secrets: Meta::CredentialDataSanitizer.channel_secrets(whatsapp_channel)
    )
    raise "#{error_message}: #{safe_body}"
  end

  def access_token
    whatsapp_channel.provider_config['api_key']
  end

  def blob_account_id(blob)
    blob.metadata.to_h['account_id'].to_i
  end

  def graph_api_query
    Whatsapp::FacebookApiClient.appsecret_proof_query(access_token)
  end

  def api_base_path
    ENV.fetch('WHATSAPP_CLOUD_BASE_URL', 'https://graph.facebook.com')
  end

  def api_version
    @api_version ||= GlobalConfigService.load('WHATSAPP_API_VERSION', 'v25.0')
  end

  def app_id
    @app_id ||= GlobalConfigService.load('WHATSAPP_APP_ID', '')
  end
end
