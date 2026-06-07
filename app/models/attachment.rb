# == Schema Information
#
# Table name: attachments
#
#  id               :integer          not null, primary key
#  coordinates_lat  :float            default(0.0)
#  coordinates_long :float            default(0.0)
#  extension        :string
#  external_url     :string
#  fallback_title   :string
#  file_type        :integer          default("image")
#  meta             :jsonb
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :integer          not null
#  message_id       :integer          not null
#
# Indexes
#
#  index_attachments_on_account_id  (account_id)
#  index_attachments_on_message_id  (message_id)
#

class Attachment < ApplicationRecord
  include Rails.application.routes.url_helpers
  include AccountStorageLimitable

  ACCEPTABLE_FILE_TYPES = %w[
    text/csv text/html text/plain text/rtf text/xml application/xml
    application/json application/pdf
    application/zip application/x-7z-compressed application/vnd.rar application/x-tar
    application/msword application/vnd.ms-excel application/vnd.ms-powerpoint application/rtf
    application/vnd.oasis.opendocument.text
    application/vnd.openxmlformats-officedocument.presentationml.presentation
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
  ].freeze
  BUSINESS_CERTIFICATE_EXTENSIONS = %w[p12 pfx].freeze
  BUSINESS_CERTIFICATE_CONTENT_TYPES = %w[application/pkcs12 application/x-pkcs12].freeze
  GENERIC_BINARY_CONTENT_TYPES = %w[application/octet-stream].freeze
  DOWNLOAD_ONLY_CONTENT_TYPES = %w[application/pkcs12 application/x-pkcs12 application/xml text/xml].freeze
  DOWNLOAD_ONLY_EXTENSIONS = %w[p12 pfx xml].freeze
  belongs_to :account
  belongs_to :message
  has_one_attached :file
  account_storage_attachments :file
  before_save :set_extension
  validate :acceptable_file
  validates :external_url, length: { maximum: Limits::URL_LENGTH_LIMIT }
  enum file_type: { :image => 0, :audio => 1, :video => 2, :file => 3, :location => 4, :fallback => 5, :share => 6, :story_mention => 7,
                    :contact => 8, :ig_reel => 9, :ig_post => 10, :ig_story => 11, :embed => 12 }

  attr_writer :skip_storage_limit_validation

  def push_event_data
    return unless file_type

    base_data.merge(metadata_for_file_type)
  end

  # NOTE: the URl returned does a 301 redirect to the actual file
  def file_url
    file.attached? ? url_for(file) : ''
  end

  # NOTE: for External services use this methods since redirect doesn't work effectively in a lot of cases
  def download_url
    ActiveStorage::Current.url_options = Rails.application.routes.default_url_options if ActiveStorage::Current.url_options.blank?
    file.attached? ? file.blob.url : ''
  end

  def thumb_url
    return '' unless file.attached? && image?

    begin
      url_for(file.representation(resize_to_fill: [250, nil]))
    rescue ActiveStorage::UnrepresentableError => e
      Rails.logger.warn "Unrepresentable image attachment: #{id} (#{file.filename}) - #{e.message}"
      ''
    end
  end

  def with_attached_file?
    [:image, :audio, :video, :file].include?(file_type.to_sym)
  end

  def skip_storage_limit_validation!
    self.skip_storage_limit_validation = true
    self
  end

  def skip_storage_limit_validation?
    ActiveModel::Type::Boolean.new.cast(@skip_storage_limit_validation)
  end

  private

  def metadata_for_file_type
    case file_type.to_sym
    when :location
      location_metadata
    when :fallback
      fallback_data
    when :contact
      contact_metadata
    when :audio
      audio_metadata
    when :embed
      embed_data
    else
      file.attached? ? file_metadata : { data_url: external_url, thumb_url: '' }
    end
  end

  def embed_data
    {
      data_url: external_url
    }
  end

  def audio_metadata
    audio_file_data = base_data.merge(file_metadata)
    audio_file_data.merge(
      {
        # Keep audio playback inline while avoiding the ActiveStorage proxy path.
        data_url: inline_audio_url,
        transcribed_text: meta&.[]('transcribed_text') || ''
      }
    )
  end

  def inline_audio_url
    return '' unless file.attached?

    Rails.application.routes.url_helpers.rails_storage_redirect_url(file, disposition: 'inline')
  end

  def attachment_download_url
    return '' unless file.attached?

    Rails.application.routes.url_helpers.rails_storage_redirect_url(file, disposition: 'attachment')
  end

  def download_only_attachment?
    DOWNLOAD_ONLY_CONTENT_TYPES.include?(file.content_type) || DOWNLOAD_ONLY_EXTENSIONS.include?(attached_file_extension)
  end

  def file_metadata
    metadata = {
      extension: extension,
      content_type: file.content_type,
      data_url: download_only_attachment? ? attachment_download_url : file_url,
      thumb_url: thumb_url,
      file_size: file.byte_size,
      width: file.metadata[:width],
      height: file.metadata[:height],
      transcribed_text: meta&.[]('transcribed_text') || '',
      parsed_text: meta&.[]('parsed_text') || '',
      document_parse_status: meta&.dig('document_parse', 'status') || ''
    }

    metadata[:data_url] = metadata[:thumb_url] = external_url if instagram_incoming_message?
    metadata
  end

  def location_metadata
    {
      coordinates_lat: coordinates_lat,
      coordinates_long: coordinates_long,
      fallback_title: fallback_title,
      data_url: external_url
    }
  end

  def fallback_data
    {
      fallback_title: fallback_title,
      data_url: external_url
    }
  end

  def base_data
    {
      id: id,
      message_id: message_id,
      file_type: file_type,
      account_id: account_id
    }
  end

  def contact_metadata
    {
      fallback_title: fallback_title,
      meta: meta || {}
    }
  end

  def instagram_incoming_message?
    return false unless message.incoming?

    return true if message.inbox.instagram_direct?

    message.inbox.instagram? && message.conversation&.additional_attributes&.dig('type') == 'instagram_direct_message'
  end

  def set_extension
    return unless file.attached?
    return if extension.present?

    self.extension = File.extname(file.filename.to_s).delete_prefix('.').presence
  end

  def should_validate_file?
    return unless file.attached?
    # we are only limiting attachment types in case of website widget
    return unless message.inbox.channel_type == 'Channel::WebWidget'

    true
  end

  def acceptable_file
    return unless should_validate_file?

    validate_file_size(file.byte_size)
    validate_file_content_type(file.content_type)
  end

  def validate_file_content_type(file_content_type)
    normalized_content_type = file_content_type.to_s.downcase

    if business_certificate_extension?
      return if business_certificate_file?(normalized_content_type)

      errors.add(:file, "type not supported: #{normalized_content_type.presence || attached_file_extension.presence || 'unknown'}")
      return
    end

    return if media_file?(normalized_content_type)
    return if ACCEPTABLE_FILE_TYPES.include?(normalized_content_type)

    errors.add(:file, "type not supported: #{normalized_content_type.presence || attached_file_extension.presence || 'unknown'}")
  end

  def validate_file_size(byte_size)
    limit_mb = GlobalConfigService.load('MAXIMUM_FILE_UPLOAD_SIZE', 40).to_i
    limit_mb = 40 if limit_mb <= 0

    errors.add(:file, 'size is too big') if byte_size > limit_mb.megabytes
  end

  def media_file?(file_content_type)
    file_content_type.start_with?('image/', 'video/', 'audio/')
  end

  def business_certificate_file?(file_content_type)
    business_certificate_extension? &&
      (BUSINESS_CERTIFICATE_CONTENT_TYPES + GENERIC_BINARY_CONTENT_TYPES).include?(file_content_type)
  end

  def business_certificate_extension?
    BUSINESS_CERTIFICATE_EXTENSIONS.include?(attached_file_extension)
  end

  def attached_file_extension
    (extension.to_s.presence || File.extname(file.filename.to_s).delete_prefix('.').presence).to_s.downcase
  end
end

Attachment.include_mod_with('Concerns::Attachment')
