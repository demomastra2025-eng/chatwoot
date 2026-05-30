# frozen_string_literal: true

require 'open3'

class Llm::OpenRouterAudioInput
  CHAT_INPUT_FORMATS = %w[mp3 wav].freeze
  TRANSCRIPTION_INPUT_FORMATS = %w[mp3 wav flac m4a ogg webm aac].freeze
  FORMAT_ALIASES = {
    'mpeg' => 'mp3',
    'mpga' => 'mp3',
    'x-m4a' => 'm4a',
    'x-wav' => 'wav',
    'wave' => 'wav',
    'oga' => 'ogg',
    'opus' => 'ogg'
  }.freeze

  NormalizationError = Class.new(StandardError)

  class << self
    def normalize_for_chat(file_path, logger_context: {})
      normalize(file_path, allowed_formats: CHAT_INPUT_FORMATS, logger_context: logger_context)
    end

    def normalize_for_transcription(file_path, logger_context: {})
      normalize(file_path, allowed_formats: TRANSCRIPTION_INPUT_FORMATS, logger_context: logger_context)
    end

    def format_for(file_path)
      normalized_format(attachment_format(file_path).presence || extension_format(file_path))
    end

    def ffmpeg_path
      ENV.fetch('AUDIO_TRANSCODER_FFMPEG_PATH', nil).presence || system_ffmpeg_path
    end

    private

    def normalize(file_path, allowed_formats:, logger_context:)
      return file_path if format_for(file_path).in?(allowed_formats)

      transcode_to_wav(file_path, logger_context: logger_context)
    end

    def attachment_format(file_path)
      RubyLLM::Attachment.new(file_path).format
    rescue StandardError
      nil
    end

    def extension_format(file_path)
      File.extname(file_path.to_s).delete_prefix('.').downcase
    end

    def normalized_format(value)
      format = value.to_s.downcase.delete_prefix('.')
      FORMAT_ALIASES.fetch(format, format)
    end

    def transcode_to_wav(source_file_path, logger_context:)
      destination_file_path = "#{source_file_path}.openrouter.wav"
      ffmpeg = ffmpeg_path
      raise NormalizationError, 'Audio transcription converter ffmpeg is not available for OpenRouter audio input' if ffmpeg.blank?

      stdout, stderr, status = Open3.capture3(
        ffmpeg,
        '-y', '-nostdin', '-hide_banner', '-loglevel', 'error',
        '-i', source_file_path,
        '-vn', '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le',
        destination_file_path
      )

      if status.success? && File.size?(destination_file_path)
        Rails.logger.info("OpenRouter audio input normalized #{formatted_context(logger_context)} output_format=wav")
        return destination_file_path
      end

      FileUtils.rm_f(destination_file_path)
      Rails.logger.warn("OpenRouter audio input normalization failed #{formatted_context(logger_context)} stderr=#{stderr.presence || stdout}")
      raise NormalizationError, 'Audio transcription normalization failed'
    end

    def system_ffmpeg_path
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |path| File.join(path, 'ffmpeg') }.find { |path| File.executable?(path) }
    end

    def formatted_context(context)
      context.to_h.compact.map { |key, value| "#{key}=#{value}" }.join(' ')
    end
  end
end
