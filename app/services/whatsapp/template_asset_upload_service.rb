class Whatsapp::TemplateAssetUploadService
  class BlobReferenceUnavailableError < ArgumentError; end
  class BlobReferenceRejectedError < ArgumentError; end

  MAX_DOWNLOAD_SIZE = Whatsapp::TemplateMediaValidator::MAX_FILE_SIZE
  ALLOWED_DOWNLOAD_PORTS = [80, 443].freeze
  UPLOAD_PURPOSE = 'whatsapp_template_media'.freeze
  CLEANUP_DELAY = 24.hours
  pattr_initialize [:whatsapp_channel!]

  class << self
    def blob_metadata(account_id:)
      {
        'account_id' => account_id,
        'upload_purpose' => UPLOAD_PURPOSE
      }
    end

    def signed_blob_id(blob, account_id:)
      blob.signed_id(purpose: signed_id_purpose(account_id))
    end

    def find_account_blob(signed_id, account_id:)
      ActiveStorage::Blob.find_signed(signed_id, purpose: signed_id_purpose(account_id))
    end

    def find_upload_blob!(signed_id, account_id:)
      ActiveStorage::Blob.find_signed!(signed_id, purpose: signed_id_purpose(account_id))
    rescue ActiveRecord::RecordNotFound
      raise BlobReferenceUnavailableError, 'Uploaded media file is invalid or no longer available'
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      find_legacy_account_blob!(signed_id, account_id: account_id)
    end

    def schedule_cleanup(blob) = ActiveStorage::PurgeJob.set(wait: CLEANUP_DELAY).perform_later(blob)

    private

    def find_legacy_account_blob!(signed_id, account_id:)
      blob = ActiveStorage::Blob.find_signed!(signed_id)
      metadata = blob&.metadata.to_h
      unless metadata['account_id'].to_s == account_id.to_s && metadata['upload_purpose'].blank?
        raise BlobReferenceRejectedError, 'Uploaded media file is invalid or no longer available'
      end

      blob
    rescue ActiveRecord::RecordNotFound, ActiveSupport::MessageVerifier::InvalidSignature
      raise BlobReferenceRejectedError, 'Uploaded media file is invalid or no longer available'
    end

    def signed_id_purpose(account_id)
      "#{UPLOAD_PURPOSE}:account:#{account_id}"
    end
  end

  def upload(url:, media_type:)
    validate_app_configuration!
    validated_url = validate_download_url!(url)

    SafeFetch.fetch(
      validated_url,
      max_bytes: MAX_DOWNLOAD_SIZE,
      redirects_remaining: 0,
      validate_content_type: false
    ) do |result|
      file = result.tempfile
      file_name = resolve_file_name(file, validated_url, media_type)
      content_type = validate_media!(file, file_name: file_name, media_type: media_type)

      upload_file_with_metadata(file, file_name: file_name, content_type: content_type)
    end
  rescue SafeFetch::Error => e
    raise ArgumentError, "Sample media URL could not be downloaded safely: #{e.message}"
  end

  def upload_blob(blob_signed_id:, media_type:)
    validate_app_configuration!
    blob = self.class.find_upload_blob!(blob_signed_id, account_id: whatsapp_channel.account_id)
    raise ArgumentError, 'Uploaded media file is already in use' if blob.attachments.exists?

    Whatsapp::TemplateMediaValidator.validate_size!(blob.byte_size)

    blob.open do |file|
      file_name = blob.filename.to_s
      content_type = validate_media!(file, file_name: file_name, media_type: media_type, byte_size: blob.byte_size)

      handle = upload_file_with_metadata(file, file_name: file_name, content_type: content_type)
      blob.purge_later
      handle
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
    raise ArgumentError, 'Sample media URL cannot include credentials' if uri.userinfo.present?
    raise ArgumentError, 'Sample media URL must use port 80 or 443' unless ALLOWED_DOWNLOAD_PORTS.include?(uri.port)

    uri.to_s
  rescue URI::InvalidURIError
    raise ArgumentError, 'Sample media URL must be a valid URL'
  end

  def parse_download_uri!(url)
    uri = URI.parse(url)
    raise ArgumentError, 'Sample media URL must start with http:// or https://' unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
    raise ArgumentError, 'Sample media URL must include a hostname' if uri.host.blank?

    uri
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
