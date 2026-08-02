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

    if cached_transcript.present?
      persist_cached_transcript!
      return { success: true, transcript: cached_transcript }
    end

    transcript = transcribe_recording.to_s.strip
    return { error: 'Empty transcript' } if transcript.blank?

    update_call_and_message!(transcript, source: 'audio_transcription')
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
      ai_voice_runtime_transcript.presence ||
      voice_message&.content_attributes&.dig('data', 'transcript').presence
  end

  def persist_cached_transcript!
    return if recording_metadata.dig('transcription', 'status') == 'completed'

    update_call_and_message!(cached_transcript, source: cached_transcript_source)
  end

  def cached_transcript_source
    if recording_metadata.dig('transcription', 'text').present?
      return recording_metadata.dig('transcription', 'source').presence || 'audio_transcription'
    end
    return 'ai_voice_runtime' if ai_voice_runtime_transcript.present?

    'voice_message'
  end

  def ai_voice_runtime_transcript
    @ai_voice_runtime_transcript ||= begin
      raw_transcript = call_session.metadata&.dig('ai_voice', 'transcript', 'final_items').presence ||
                       call_session.metadata&.dig('ai_voice', 'final_transcript')
      format_runtime_transcript(raw_transcript)
    end
  end

  def format_runtime_transcript(raw_transcript)
    return raw_transcript if raw_transcript.is_a?(String)

    Array(raw_transcript).filter_map do |raw_item|
      item = raw_item.to_h.with_indifferent_access
      text = item[:text].to_s.strip
      next if text.blank?

      "#{transcript_speaker_label(item[:speaker])}: #{text}"
    end.join("\n")
  end

  def transcript_speaker_label(speaker)
    speaker.to_s.in?(%w[caller customer contact user]) ? 'Клиент' : 'Оператор'
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

  def update_call_and_message!(transcript, source:)
    transcript_ref = "call_recording_transcript:#{call_session.external_call_ref}"

    call_session.with_lock do
      metadata = (call_session.reload.metadata || {}).deep_dup
      recording = metadata['recording'] ||= {}
      recording['transcription'] = {
        'status' => 'completed',
        'source' => source,
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

    content_attributes = normalized_content_attributes(message)
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

  def normalized_content_attributes(message)
    raw_attributes = message&.content_attributes
    attributes = if raw_attributes.is_a?(String)
                   JSON.parse(raw_attributes)
                 elsif raw_attributes.respond_to?(:to_h)
                   raw_attributes.to_h
                 else
                   {}
                 end

    return {} unless attributes.is_a?(Hash)

    attributes.deep_dup.deep_stringify_keys
  rescue JSON::ParserError
    {}
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
