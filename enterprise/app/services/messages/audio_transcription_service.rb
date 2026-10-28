class Messages::AudioTranscriptionService < Llm::BaseAiService
  include Integrations::LlmInstrumentation

  # Transcription is reading, not writing: the most likely text, the same on every run. A higher temperature made
  # gpt-4o-mini-transcribe drift between Kazakh and Kyrgyz spelling on short Kazakh clips.
  TRANSCRIPTION_TEMPERATURE = 0

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
    return false unless account.audio_transcriptions_enabled?

    account.captain_quota_available?
  end

  def audio_file
    @audio_file ||= Messages::AudioTranscriptionFile.new(attachment)
  end

  def fetch_audio_file
    audio_file.copy_to_temp_file
  end

  def transcribe_audio
    return cached_transcription if cached_transcription.present?

    temp_file_path = fetch_audio_file
    provider_file_path = audio_file_path_for_provider(temp_file_path)
    observability = instrumentation_params(provider_file_path)
    response = instrument_audio_transcription(observability) { request_transcription(provider_file_path, observability) }
    transcribed_text = transcription_prompt.without_echoed_context(response_text(response))

    update_transcription(transcribed_text)
    transcribed_text
  ensure
    remove_temp_files(temp_file_path, provider_file_path)
  end

  def request_transcription(provider_file_path, observability)
    return transcribe_with_openrouter_chat(provider_file_path, observability) if openrouter_chat_transcription?

    transcribe_with_transcription_endpoint(provider_file_path, observability)
  end

  def response_text(response)
    response.respond_to?(:text) ? response.text.to_s : response.to_s
  end

  def remove_temp_files(*paths)
    paths.compact_blank.uniq.each { |path| FileUtils.rm_f(path) }
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
    @transcription_prompt ||= Messages::AudioTranscriptionPrompt.new(account.captain_audio_transcription_prompt)
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

  # No `language`: it stays detected per message, because many voice messages are in Russian
  def transcribe_with_transcription_endpoint(temp_file_path, observability)
    Llm::Runtime.transcribe(
      feature: :audio_transcription,
      account: account,
      model: model,
      input: temp_file_path,
      observability: observability.merge(runtime_mode: 'audio_transcription', provider: 'openrouter'),
      options: { temperature: TRANSCRIPTION_TEMPERATURE, prompt: transcription_prompt.for_transcription_endpoint }
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
          content: RubyLLM::Content.new(transcription_prompt.for_chat, [temp_file_path])
        }
      ],
      observability: observability.merge(runtime_mode: 'audio_transcription', provider: 'openrouter'),
      options: openrouter_chat_options
    )

    response&.content.to_s
  end

  def openrouter_chat_options
    return { temperature: TRANSCRIPTION_TEMPERATURE } unless model.to_s.include?('gemini-3')

    { temperature: 0.1, params: { reasoning: { effort: 'minimal' } } }
  end

  def update_transcription(transcribed_text)
    return if transcribed_text.blank?

    attachment.update!(meta: attachment.meta.to_h.merge('transcribed_text' => transcribed_text))
    message.reload.send_update_event
    message.account.increment_response_usage

    return unless ChatwootApp.advanced_search_allowed?

    message.reindex
  end

  def supported_attachment_format?
    audio_file.supported?
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
