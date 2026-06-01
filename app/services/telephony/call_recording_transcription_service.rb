class Telephony::CallRecordingTranscriptionService < Llm::BaseAiService
  include Integrations::LlmInstrumentation

  class RecordingNotFound < StandardError; end

  TranscriptionResult = Struct.new(:text, keyword_init: true)

  attr_reader :call_session, :account

  def initialize(call_session)
    @call_session = call_session
    @account = call_session.account
    super()
  end

  def perform
    return { error: 'Transcription not available' } unless can_transcribe?
    return { success: true, transcript: cached_transcript } if cached_transcript.present?

    transcript = transcribe_recording.to_s.strip
    return { error: 'Empty transcript' } if transcript.blank?

    update_call_and_message!(transcript)
    account.increment_response_usage

    { success: true, transcript: transcript }
  rescue RubyLLM::UnauthorizedError, Faraday::UnauthorizedError
    Rails.logger.warn(
      '[TELEPHONY] Skipping call recording transcription: LLM provider configuration is invalid ' \
      "account_id=#{account.id} call_session_id=#{call_session.id}"
    )
    { error: 'LLM transcription provider configuration is invalid' }
  end

  private

  def can_transcribe?
    account.feature_enabled?('captain_integration') &&
      account.captain_audio_transcription_enabled? &&
      account.captain_quota_available?
  end

  def cached_transcript
    call_session.metadata&.dig('recording', 'transcription', 'text').presence ||
      voice_message&.content_attributes&.dig('data', 'transcript').presence
  end

  def transcribe_recording
    file_path = recording_file_path!
    provider_file_path = audio_file_path_for_provider(file_path)
    response = if openrouter_chat_transcription?
                 transcribe_with_openrouter_chat(provider_file_path)
               else
                 transcribe_with_transcription_endpoint(provider_file_path)
               end

    response.respond_to?(:text) ? response.text.to_s : response.to_s
  ensure
    FileUtils.rm_f(provider_file_path) if provider_file_path.present? && provider_file_path != file_path
  end

  def transcribe_with_transcription_endpoint(file_path)
    observability = instrumentation_params(file_path)
    instrument_audio_transcription(observability) do
      Llm::Runtime.transcribe(
        feature: :audio_transcription,
        account: account,
        model: model,
        input: file_path,
        observability: observability.merge(runtime_mode: 'call_recording_transcription', provider: 'openrouter'),
        options: { temperature: 0.2, prompt: transcription_prompt }
      )
    end
  end

  def transcribe_with_openrouter_transcription_endpoint(file_path)
    observability = instrumentation_params(file_path).merge(provider: 'openrouter')
    instrument_audio_transcription(observability) do
      Llm::Runtime.transcribe(
        feature: :audio_transcription,
        account: account,
        model: model,
        input: file_path,
        observability: observability.merge(runtime_mode: 'call_recording_transcription'),
        options: { temperature: 0.2, prompt: transcription_prompt }
      )
    end
  end

  def transcribe_with_openrouter_chat(file_path)
    observability = instrumentation_params(file_path).merge(provider: 'openrouter')
    response = instrument_audio_transcription(observability) do
      Llm::Runtime.chat(
        feature: :audio_transcription,
        account: account,
        model: model,
        messages: [
          {
            role: 'user',
            content: RubyLLM::Content.new(openrouter_transcription_prompt, [file_path])
          }
        ],
        observability: observability.merge(runtime_mode: 'call_recording_transcription'),
        options: { temperature: 0 }
      )
    end

    TranscriptionResult.new(text: response&.content.to_s)
  end

  def recording_file_path!
    storage_key = recording_storage_key
    raise RecordingNotFound, 'Recording storage key is missing' if storage_key.blank?

    raise RecordingNotFound, 'Recording file could not be found' unless storage_key.start_with?('voice-recordings/')

    storage_root = Rails.root.join('storage').realpath
    path = storage_root.join(storage_key).cleanpath
    raise RecordingNotFound, 'Recording file could not be found' unless path.to_s.start_with?("#{storage_root}/") && File.file?(path)

    real_path = Pathname.new(File.realpath(path.to_s))
    raise RecordingNotFound, 'Recording file could not be found' unless real_path.to_s.start_with?("#{storage_root}/")

    real_path.to_s
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
    raise RecordingNotFound, 'Recording file could not be found'
  end

  def recording_storage_key
    recording_metadata['storage_key'].presence || recording_metadata['recording_ref'].presence || call_session.recording_ref.presence
  end

  def recording_metadata
    metadata = call_session.metadata
    recording = metadata.is_a?(Hash) ? metadata['recording'] : nil
    recording.is_a?(Hash) ? recording.deep_stringify_keys : {}
  end

  def update_call_and_message!(transcript)
    transcript_ref = "call_recording_transcript:#{call_session.external_call_ref}"

    call_session.with_lock do
      metadata = (call_session.reload.metadata || {}).deep_dup
      recording = metadata['recording'] ||= {}
      recording['transcription'] = {
        'status' => 'completed',
        'source' => 'audio_transcription',
        'text' => transcript,
        'completed_at' => Time.current.iso8601
      }
      call_session.update!(metadata: metadata, transcript_ref: transcript_ref)
    end

    update_voice_message!(transcript, transcript_ref)
  end

  def update_voice_message!(transcript, transcript_ref)
    message = voice_message
    return if message.blank?

    content_attributes = (message.content_attributes || {}).deep_dup.deep_stringify_keys
    content_attributes['data'] ||= {}
    content_attributes['data']['transcript_ref'] = transcript_ref
    content_attributes['data']['transcript'] = transcript
    content_attributes['data']['recording'] = recording_metadata if recording_metadata.present?
    message.update!(content_attributes: content_attributes)
    message.reload.send_update_event
  end

  def voice_message
    @voice_message ||= call_session.voice_message_for_current_call
  end

  def instrumentation_params(file_path)
    {
      span_name: 'llm.telephony.call_recording_transcription',
      provider: provider_name,
      model: model,
      account_id: account.id,
      feature_name: 'audio_transcription',
      input: { file_name: File.basename(file_path.to_s) }
    }
  end

  def transcription_prompt
    [
      'Transcribe the attached call recording accurately. Return only the transcript text, without markdown or commentary.',
      'If speaker roles are clear, label them as Клиент and Оператор.',
      account.captain_audio_transcription_prompt.presence
    ].compact.join("\n")
  end

  def openrouter_transcription_prompt
    transcription_prompt
  end

  def openrouter_chat_transcription?
    provider_name == 'openrouter' &&
      Llm::Models.type_for(model, account: account) == 'chat' &&
      Llm::Models.supports_audio_input?(model, account: account)
  end

  def openrouter_transcription_endpoint?
    provider_name == 'openrouter' && Llm::Models.type_for(model, account: account) == 'transcription'
  end

  def audio_file_path_for_provider(file_path)
    if openrouter_chat_transcription?
      return Llm::OpenRouterAudioInput.normalize_for_chat(
        file_path,
        logger_context: { account_id: account.id, call_session_id: call_session.id }
      )
    end

    if openrouter_transcription_endpoint?
      return Llm::OpenRouterAudioInput.normalize_for_transcription(
        file_path,
        logger_context: { account_id: account.id, call_session_id: call_session.id }
      )
    end

    file_path
  end

  def provider_name
    @provider_name ||= Llm::Config.provider_for_model(model, account: account)
  end

  def llm_feature_key
    'audio_transcription'
  end

  def llm_model_account
    account
  end
end
