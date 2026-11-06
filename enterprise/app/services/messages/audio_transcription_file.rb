# frozen_string_literal: true

# The audio of a voice message attachment as the transcription providers take it: whether its format is one they
# accept, and a local copy whose extension names that format (WhatsApp Web sends audio/opus without an extension).
class Messages::AudioTranscriptionFile
  SUPPORTED_EXTENSIONS = %w[aac flac m4a mp3 mp4 mpeg mpga oga ogg wav webm].freeze
  CONTENT_SUBTYPE_EXTENSIONS = { 'x-m4a' => 'm4a', 'x-wav' => 'wav', 'x-mp3' => 'mp3', 'opus' => 'ogg' }.freeze
  TEMP_DIRECTORY = 'tmp/uploads/audio-transcriptions'

  def initialize(attachment)
    @attachment = attachment
  end

  def supported?
    extension.present?
  end

  def canonical_extension
    extension
  end

  # Copies the audio into a temp file and returns its path; the caller removes the file
  def copy_to_temp_file
    blob = @attachment.file.blob
    temp_dir = Rails.root.join(TEMP_DIRECTORY)
    FileUtils.mkdir_p(temp_dir)
    temp_file_path = File.join(temp_dir, temp_file_name(blob))

    File.open(temp_file_path, 'wb') do |file|
      blob.open { |blob_file| IO.copy_stream(blob_file, file) }
    end

    temp_file_path
  end

  private

  def extension
    return @extension if defined?(@extension)

    @extension = candidate_extensions.find { |candidate| candidate.in?(SUPPORTED_EXTENSIONS) }
  end

  def candidate_extensions
    return [] unless @attachment.file.attached?

    blob = @attachment.file.blob
    [
      extension_from_content_type(blob.content_type),
      blob.filename.extension_without_delimiter
    ].filter_map { |candidate| candidate.to_s.downcase.presence }
  end

  def extension_from_content_type(content_type)
    subtype = content_type.to_s.downcase.split(';').first.to_s.split('/').last.to_s
    return if subtype.blank?

    CONTENT_SUBTYPE_EXTENSIONS.fetch(subtype, subtype)
  end

  def temp_file_name(blob)
    original_filename = blob.filename
    filename_extension = original_filename.extension_without_delimiter.to_s.downcase
    target_extension = extension || extension_from_content_type(blob.content_type)

    return "#{blob.key}-#{original_filename}" if target_extension.blank? || filename_extension == target_extension

    filename_base = original_filename.base.presence || original_filename.to_s
    "#{blob.key}-#{filename_base}.#{target_extension}"
  end
end
