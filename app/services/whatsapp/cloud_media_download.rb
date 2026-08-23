class Whatsapp::CloudMediaDownload
  class MetadataFetchError < StandardError; end

  MEDIA_TYPES = %w[audio document image sticker video].freeze

  pattr_initialize [:channel!, :params!, :outgoing_echo]

  attr_reader :file

  def self.prepare(channel:, params:, outgoing_echo: false)
    download = new(channel: channel, params: params, outgoing_echo: outgoing_echo)
    return unless download.media_candidate?

    download.resolve_download!
  end

  def media_candidate?
    media_id.present?
  end

  def resolve_download!
    headers = channel.api_headers.to_h.deep_dup
    response = HTTParty.get(channel.media_url(media_id), headers: headers)
    record_authorization_error! if response.unauthorized?
    raise MetadataFetchError, 'WhatsApp media metadata request failed' unless response.success?

    @download_url = response.parsed_response.to_h['url'].presence
    raise MetadataFetchError, 'WhatsApp media metadata response did not include a URL' if @download_url.blank?

    @download_headers = headers
    self
  end

  def download!
    return self if @download_url.blank?

    @file = Down.download(
      @download_url,
      headers: @download_headers,
      max_redirects: 0,
      max_size: maximum_download_size
    )
    self
  ensure
    @download_headers = nil
  end

  def matches?(attachment_payload)
    attachment_payload.to_h.with_indifferent_access[:id].to_s == media_id
  end

  def close
    return if file.blank?

    file.close! if file.respond_to?(:close!)
    file.close if file.respond_to?(:close) && (!file.respond_to?(:closed?) || !file.closed?)
  rescue StandardError
    nil
  end

  private

  attr_reader :channel, :outgoing_echo, :params

  def maximum_download_size
    limit_mb = GlobalConfigService.load('MAXIMUM_FILE_UPLOAD_SIZE', 40).to_i
    limit_mb = 40 if limit_mb <= 0
    limit_mb.megabytes
  end

  def record_authorization_error!
    channel.authorization_error!
  ensure
    raise MetadataFetchError, 'WhatsApp media metadata request failed'
  end

  def media_id
    @media_id ||= attachment_payload[:id].to_s.presence
  end

  def attachment_payload
    return {} unless MEDIA_TYPES.include?(message_type)

    message_data[message_type].to_h.with_indifferent_access
  end

  def message_type
    @message_type ||= message_data[:type].to_s
  end

  def message_data
    @message_data ||= begin
      value = params.dig(:entry, 0, :changes, 0, :value).to_h.with_indifferent_access
      collection = if outgoing_echo
                     value[:message_echoes].presence || value[:smb_message_echoes].presence || value[:messages]
                   else
                     value[:messages]
                   end
      Array(collection).first.to_h.with_indifferent_access
    end
  end
end
