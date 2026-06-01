class Messages::AudioTranscriptionService < Llm::BaseAiService
  include Integrations::LlmInstrumentation
  SUPPORTED_AUDIO_EXTENSIONS = %w[
    aac
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
    return { success: true, transcriptions: cached_transcription } if cached_transcription.present?
    return unsupported_audio_format_result unless supported_attachment_format?

    transcriptions = transcribe_audio
    Rails.logger.info(
      'Audio transcription completed ' \
      "attachment_id=#{attachment.id} message_id=#{message.id}"
    )
    { success: true, transcriptions: transcriptions }
  rescue RubyLLM::UnauthorizedError, Faraday::UnauthorizedError
    Rails.logger.warn('Skipping audio transcription: LLM transcription provider configuration is invalid or disabled (401 Unauthorized).')
    { error: 'LLM transcription provider configuration is invalid or disabled (401)' }
  end

  private

  def can_transcribe?
    return false unless account.feature_enabled?('captain_integration')
    return false unless account.captain_audio_transcription_enabled?

    account.captain_quota_available?
  end

  def fetch_audio_file
    blob = attachment.file.blob
    temp_dir = Rails.root.join('tmp/uploads/audio-transcriptions')
    FileUtils.mkdir_p(temp_dir)
    temp_file_name = transcription_temp_file_name(blob)

    temp_file_path = File.join(temp_dir, temp_file_name)

    File.open(temp_file_path, 'wb') do |file|
      blob.open do |blob_file|
        IO.copy_stream(blob_file, file)
      end
    end

    temp_file_path
  end

  def transcribe_audio
    transcribed_text = cached_transcription || ''
    return transcribed_text if transcribed_text.present?

    temp_file_path = fetch_audio_file
    provider_file_path = audio_file_path_for_provider(temp_file_path)
    observability = instrumentation_params(provider_file_path)
    response = instrument_audio_transcription(observability) do
      if openrouter_chat_transcription?
        transcribe_with_openrouter_chat(provider_file_path, observability)
      else
        transcribe_with_transcription_endpoint(provider_file_path, observability)
      end
    end
    transcribed_text = response.respond_to?(:text) ? response.text.to_s : response.to_s

    update_transcription(transcribed_text)
    transcribed_text
  ensure
    FileUtils.rm_f(temp_file_path) if temp_file_path.present?
    FileUtils.rm_f(provider_file_path) if provider_file_path.present? && provider_file_path != temp_file_path
  end

  def instrumentation_params(file_path)
    {
      span_name: 'llm.messages.audio_transcription',
      model: model,
      provider: Llm::Config.provider_for_model(model, account: account),
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

  def transcription_prompt
    account.captain_audio_transcription_prompt
  end

  def openrouter_chat_transcription?
    Llm::Config.provider_for_model(model, account: account) == 'openrouter' &&
      Llm::Models.type_for(model, account: account) == 'chat' &&
      Llm::Models.supports_audio_input?(model, account: account)
  end

  def openrouter_transcription_endpoint?
    Llm::Config.provider_for_model(model, account: account) == 'openrouter' &&
      Llm::Models.type_for(model, account: account) == 'transcription'
  end

  def audio_file_path_for_provider(temp_file_path)
    if openrouter_chat_transcription?
      return Llm::OpenRouterAudioInput.normalize_for_chat(
        temp_file_path,
        logger_context: { attachment_id: attachment.id, message_id: message.id }
      )
    end

    if openrouter_transcription_endpoint?
      return Llm::OpenRouterAudioInput.normalize_for_transcription(
        temp_file_path,
        logger_context: { attachment_id: attachment.id, message_id: message.id }
      )
    end

    temp_file_path
  end

  def transcribe_with_transcription_endpoint(temp_file_path, observability)
    Llm::Runtime.transcribe(
      feature: :audio_transcription,
      account: account,
      model: model,
      input: temp_file_path,
      observability: observability.merge(runtime_mode: 'audio_transcription', provider: 'openrouter'),
      options: { temperature: 0.4, prompt: transcription_prompt }
    )
  end

  def transcribe_with_openrouter_chat(temp_file_path, observability)
    response = Llm::Runtime.chat(
      feature: :audio_transcription,
      account: account,
      model: model,
      messages: [
        {
          role: 'user',
          content: RubyLLM::Content.new(openrouter_transcription_prompt, [temp_file_path])
        }
      ],
      observability: observability.merge(runtime_mode: 'audio_transcription', provider: 'openrouter'),
      options: { temperature: 0 }
    )

    response&.content.to_s
  end

  def openrouter_transcription_prompt
    [
      'Transcribe the attached audio accurately. Return only the transcript text, without markdown or commentary.',
      transcription_prompt.presence
    ].compact.join("\n")
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
      'x-mp3' => 'mp3',
      'opus' => 'ogg'
    }.fetch(subtype, subtype)
  end

  def transcription_temp_file_name(blob)
    original_filename = blob.filename
    filename_extension = original_filename.extension_without_delimiter.to_s.downcase
    extension = supported_audio_extension || extension_from_content_type(blob.content_type)

    return "#{blob.key}-#{original_filename}" if extension.blank? || filename_extension == extension

    filename_base = original_filename.base.presence || original_filename.to_s
    "#{blob.key}-#{filename_base}.#{extension}"
  end

  def supported_attachment_format?
    supported_audio_extension.present?
  end

  def supported_audio_extension
    return @supported_audio_extension if defined?(@supported_audio_extension)

    @supported_audio_extension = supported_audio_extensions.find { |extension| extension.in?(SUPPORTED_AUDIO_EXTENSIONS) }
  end

  def supported_audio_extensions
    return [] unless attachment.file.attached?

    blob = attachment.file.blob
    [
      extension_from_content_type(blob.content_type),
      blob.filename.extension_without_delimiter
    ].filter_map { |extension| extension.to_s.downcase.presence }
  end

  def unsupported_audio_format_result
    blob = attachment.file.blob if attachment.file.attached?
    Rails.logger.warn(
      'Skipping audio transcription: unsupported format ' \
      "attachment_id=#{attachment.id} message_id=#{message.id} " \
      "filename=#{blob&.filename} content_type=#{blob&.content_type}"
    )

    { error: 'Unsupported audio format' }
  end

  def cached_transcription
    attachment.meta&.[]('transcribed_text').to_s.presence
  end
end
