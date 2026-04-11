class Messages::AudioTranscriptionService < Llm::BaseAiService
  include Integrations::LlmInstrumentation
  SUPPORTED_AUDIO_EXTENSIONS = %w[
    flac
    m4a
    mp3
    mp4
    mpeg
    mpga
    oga
    ogg
    wav
    webm
  ].freeze

  attr_reader :attachment, :message, :account

  def initialize(attachment)
    @attachment = attachment
    @message = attachment.message
    @account = message.account
    super()
  end

  def perform
    return { error: 'Transcription limit exceeded' } unless can_transcribe?
    return { error: 'Message not found' } if message.blank?
    return unsupported_audio_format_result unless supported_attachment_format?

    transcriptions = transcribe_audio
    Rails.logger.info(
      "Audio transcription completed " \
      "attachment_id=#{attachment.id} message_id=#{message.id}"
    )
    { success: true, transcriptions: transcriptions }
  rescue RubyLLM::UnauthorizedError, Faraday::UnauthorizedError
    Rails.logger.warn('Skipping audio transcription: OpenAI configuration is invalid or disabled (401 Unauthorized).')
    { error: 'OpenAI configuration is invalid or disabled (401)' }
  end

  private

  def can_transcribe?
    return false unless account.feature_enabled?('captain_integration')
    return false if account.audio_transcriptions.blank?

    account.captain_quota_available?
  end

  def fetch_audio_file
    blob = attachment.file.blob
    temp_dir = Rails.root.join('tmp/uploads/audio-transcriptions')
    FileUtils.mkdir_p(temp_dir)
    temp_file_name = "#{blob.key}-#{blob.filename}"

    if blob.filename.extension_without_delimiter.blank?
      extension = extension_from_content_type(blob.content_type)
      temp_file_name = "#{temp_file_name}.#{extension}" if extension.present?
    end

    temp_file_path = File.join(temp_dir, temp_file_name)

    File.open(temp_file_path, 'wb') do |file|
      blob.open do |blob_file|
        IO.copy_stream(blob_file, file)
      end
    end

    temp_file_path
  end

  def transcribe_audio
    transcribed_text = attachment.meta&.[]('transcribed_text') || ''
    return transcribed_text if transcribed_text.present?

    temp_file_path = fetch_audio_file
    response = instrument_audio_transcription(instrumentation_params(temp_file_path)) do
      Llm::Config.with_api_key(api_key, api_base: api_base) do |context|
        Llm::ApiClient.transcribe(
          temp_file_path,
          context: context,
          model: model,
          temperature: 0.4
        )
      end
    end
    transcribed_text = response&.text.to_s

    update_transcription(transcribed_text)
    transcribed_text
  ensure
    FileUtils.rm_f(temp_file_path) if temp_file_path.present?
  end

  def instrumentation_params(file_path)
    {
      span_name: 'llm.messages.audio_transcription',
      model: model,
      account_id: account&.id,
      feature_name: 'audio_transcription',
      file_path: file_path
    }
  end

  def llm_feature_key
    'audio_transcription'
  end

  def llm_model_account
    account
  end

  def api_key
    @api_key ||= system_api_key.presence || openai_hook&.settings&.dig('api_key')
  end

  def api_base
    Llm::Config.api_base
  end

  def openai_hook
    @openai_hook ||= account.hooks.find_by(app_id: 'openai', status: 'enabled')
  end

  def system_api_key
    @system_api_key ||= InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value
  end

  def update_transcription(transcribed_text)
    return if transcribed_text.blank?

    attachment.update!(meta: { transcribed_text: transcribed_text })
    message.reload.send_update_event
    message.account.increment_response_usage

    return unless ChatwootApp.advanced_search_allowed?

    message.reindex
  end

  def extension_from_content_type(content_type)
    subtype = content_type.to_s.downcase.split(';').first.to_s.split('/').last.to_s
    return if subtype.blank?

    {
      'x-m4a' => 'm4a',
      'x-wav' => 'wav',
      'x-mp3' => 'mp3'
    }.fetch(subtype, subtype)
  end

  def supported_attachment_format?
    supported_audio_extension.present?
  end

  def supported_audio_extension
    @supported_audio_extension ||= begin
      blob = attachment.file.blob
      extension = blob.filename.extension_without_delimiter.presence || extension_from_content_type(blob.content_type)
      normalized_extension = extension.to_s.downcase.presence

      normalized_extension if normalized_extension.present? && normalized_extension.in?(SUPPORTED_AUDIO_EXTENSIONS)
    end
  end

  def unsupported_audio_format_result
    Rails.logger.warn(
      "Skipping audio transcription: unsupported format " \
      "attachment_id=#{attachment.id} message_id=#{message.id} " \
      "filename=#{attachment.file.blob.filename} content_type=#{attachment.file.blob.content_type}"
    )

    { error: 'Unsupported audio format' }
  end
end
