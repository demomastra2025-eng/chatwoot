class Whatsapp::TemplateSendMediaUploadService
  CACHE_TTL = 25.days
  MAX_DOWNLOAD_SIZE = Whatsapp::TemplateMediaValidator::MAX_FILE_SIZE

  pattr_initialize [:whatsapp_channel!]

  def call(media_type:, source: nil, temporary_blob_signed_id: nil)
    raise ArgumentError, 'Carousel file upload requires WhatsApp Cloud' unless whatsapp_channel.provider == 'whatsapp_cloud'

    normalized_media_type = media_type.to_s.downcase
    validate_media_type!(normalized_media_type)

    if temporary_blob_signed_id.present?
      blob = Whatsapp::TemplateAssetUploadService.find_upload_blob!(
        temporary_blob_signed_id,
        account_id: whatsapp_channel.account_id
      )
      return upload_blob(blob, normalized_media_type)
    end

    validate_source!(source, normalized_media_type)
    return source.meta_media_id if cached_media_id?(source)

    media_id = if source.file.attached?
                 upload_blob(source.file.blob, normalized_media_type)
               else
                 upload_url(source.source_url, normalized_media_type)
               end
    source.update!(meta_media_id: media_id, meta_media_uploaded_at: Time.current)
    media_id
  end

  private

  def validate_media_type!(media_type)
    return if Whatsapp::TemplateMediaSource::MEDIA_TYPES.include?(media_type)

    raise ArgumentError, "Unsupported carousel media type: #{media_type}"
  end

  def validate_source!(source, media_type)
    unless source&.whatsapp_channel_id == whatsapp_channel.id && source.media_type == media_type
      raise ArgumentError, 'Carousel media file is missing or belongs to another channel'
    end
    return if source.file.attached? || source.source_url.present?

    raise ArgumentError, 'Carousel media file is no longer available'
  end

  def cached_media_id?(source)
    source.meta_media_id.present? && source.meta_media_uploaded_at.present? &&
      source.meta_media_uploaded_at > CACHE_TTL.ago
  end

  def upload_blob(blob, media_type)
    Whatsapp::TemplateMediaValidator.validate_size!(blob.byte_size)

    blob.open do |file|
      content_type = Whatsapp::TemplateMediaValidator.validate!(
        io: file,
        file_name: blob.filename.to_s,
        media_type: media_type,
        byte_size: blob.byte_size
      )
      upload_file(file, content_type)
    end
  end

  def upload_url(url, media_type)
    SafeFetch.fetch(
      url,
      max_bytes: MAX_DOWNLOAD_SIZE,
      redirects_remaining: 0,
      validate_content_type: false
    ) do |result|
      file = result.tempfile
      file_name = result.filename.presence || "carousel.#{media_type == 'image' ? 'jpg' : 'mp4'}"
      content_type = Whatsapp::TemplateMediaValidator.validate!(
        io: file,
        file_name: file_name,
        media_type: media_type,
        byte_size: file.size
      )
      upload_file(file, content_type)
    end
  rescue SafeFetch::Error => e
    raise ArgumentError, "Carousel media URL could not be downloaded safely: #{e.message}"
  end

  def upload_file(file, content_type)
    file.rewind if file.respond_to?(:rewind)
    response = media_upload_response(file, content_type)
    return response.parsed_response.fetch('id') if response.success?

    whatsapp_channel.record_provider_authorization_error!(response.parsed_response) if response.respond_to?(:unauthorized?) && response.unauthorized?
    safe_body = Meta::CredentialDataSanitizer.sanitize(
      response.body.to_s.first(5000),
      secrets: Meta::CredentialDataSanitizer.channel_secrets(whatsapp_channel)
    )
    raise "Failed to upload WhatsApp carousel media: #{safe_body}"
  end

  def media_upload_response(file, content_type)
    HTTParty.post(
      "#{api_base_path}/#{api_version}/#{phone_number_id}/media",
      headers: { 'Authorization' => "Bearer #{access_token}" },
      query: Whatsapp::FacebookApiClient.appsecret_proof_query(access_token),
      multipart: true,
      stream_body: false,
      body: {
        messaging_product: 'whatsapp',
        type: content_type,
        file: file
      },
      timeout: 120
    )
  end

  def access_token
    whatsapp_channel.provider_config['api_key']
  end

  def phone_number_id
    whatsapp_channel.provider_config.fetch('phone_number_id')
  end

  def api_base_path
    ENV.fetch('WHATSAPP_CLOUD_BASE_URL', 'https://graph.facebook.com')
  end

  def api_version
    @api_version ||= GlobalConfigService.load('WHATSAPP_API_VERSION', 'v25.0')
  end
end
