class Whatsapp::TemplateMediaValidator
  class InvalidMediaError < ArgumentError; end

  MAX_FILE_SIZE = 25.megabytes
  SUPPORTED_MIME_TYPES = {
    'image' => %w[image/jpeg image/png],
    'video' => %w[video/mp4],
    'document' => %w[application/pdf]
  }.freeze

  def self.validate!(io:, file_name:, media_type:, byte_size:)
    new(io: io, file_name: file_name, media_type: media_type, byte_size: byte_size).validate!
  end

  def self.validate_size!(byte_size)
    return if byte_size.to_i <= MAX_FILE_SIZE

    raise InvalidMediaError, 'Uploaded media file is too large'
  end

  def initialize(io:, file_name:, media_type:, byte_size:)
    @io = io
    @file_name = file_name.to_s
    @media_type = media_type.to_s.downcase
    @byte_size = byte_size.to_i
  end

  def validate!
    self.class.validate_size!(@byte_size)

    supported_types = SUPPORTED_MIME_TYPES.fetch(@media_type) do
      raise InvalidMediaError, "Unsupported header media type: #{@media_type}"
    end
    content_type = detected_content_type
    return content_type if supported_types.include?(content_type)

    raise InvalidMediaError, "Unsupported #{@media_type} file type: #{content_type}"
  end

  private

  def detected_content_type
    @io.rewind if @io.respond_to?(:rewind)
    Marcel::MimeType.for(@io, name: @file_name) || 'application/octet-stream'
  ensure
    @io.rewind if @io.respond_to?(:rewind)
  end
end
