class Whatsapp::CallTranscriptionService < Llm::BaseAiService
  include Integrations::LlmInstrumentation

  WHISPER_MODEL = 'whisper-1'.freeze
  TranscriptionResult = Struct.new(:text, :segments, keyword_init: true)

  attr_reader :call, :account

  def initialize(call)
    @call = call
    @account = call.account
    super()
  end

  def perform
    return { error: 'Transcription not available' } unless can_transcribe?
    return { error: 'No recording attached' } unless call.recording.attached?

    transcribed_text = transcribe_audio
    update_call_and_message(transcribed_text)
    { success: true, transcript: transcribed_text }
  rescue RubyLLM::UnauthorizedError, Faraday::UnauthorizedError
    Rails.logger.warn('[WHATSAPP CALL] Skipping transcription: LLM transcription provider configuration is invalid (401)')
    { error: 'LLM transcription provider configuration is invalid' }
  end

  private

  def can_transcribe?
    account.call_transcriptions_enabled? && account.captain_quota_available?
  end

  # Transcribe per-direction recordings separately when possible so lines can
  # be attributed to Customer vs Agent. Falls back to the combined recording
  # if the media server isn't available or per-side files are missing.
  def transcribe_audio
    return transcribe_combined if openrouter_chat_transcription? || openrouter_transcription_endpoint?

    if call.media_session_id.present?
      diarized = diarized_transcript
      return diarized if diarized.present?
    end

    transcribe_combined
  end

  def diarized_transcript
    temp_dir = Rails.root.join('tmp/uploads/call-transcriptions')
    FileUtils.mkdir_p(temp_dir)
    customer_path = File.join(temp_dir, "#{call.media_session_id}_customer.ogg")
    agent_path    = File.join(temp_dir, "#{call.media_session_id}_agent.ogg")

    client = Whatsapp::MediaServerClient.new
    File.binwrite(customer_path, client.download_recording(call.media_session_id, side: 'customer'))
    File.binwrite(agent_path,    client.download_recording(call.media_session_id, side: 'agent'))

    segments = transcribe_segments(customer_path, 'Customer') +
               transcribe_segments(agent_path, 'Agent')
    return nil if segments.empty?

    segments.sort_by { |s| s[:start] }
            .map { |s| "[#{format_ts(s[:start])}] #{s[:speaker]}: #{s[:text].strip}" }
            .reject { |line| line.end_with?(': ') }
            .join("\n")
  rescue Whatsapp::MediaServerClient::ConnectionError, Whatsapp::MediaServerClient::SessionError => e
    Rails.logger.warn "[WHATSAPP CALL] Per-side recording unavailable, falling back to combined transcription: #{e.message}"
    nil
  ensure
    FileUtils.rm_f(customer_path) if defined?(customer_path) && customer_path
    FileUtils.rm_f(agent_path)    if defined?(agent_path) && agent_path
  end

  def transcribe_segments(file_path, speaker)
    return [] unless File.exist?(file_path) && File.size(file_path).positive?

    response = transcribe_file(
      file_path,
      temperature: 0.2,
      response_format: 'verbose_json',
      timestamp_granularities: ['segment'],
      observability: instrumentation_params(file_path, 'call_side_transcription')
    )
    segments = Array(response&.segments)

    return [{ speaker: speaker, start: 0.0, text: response.text.to_s }] if segments.empty? && response&.text.present?

    segments.map do |seg|
      segment = seg.with_indifferent_access
      { speaker: speaker, start: segment[:start].to_f, text: segment[:text].to_s }
    end
  end

  def transcribe_combined
    temp_file_path = fetch_combined_recording
    response = transcribe_file(
      temp_file_path,
      temperature: 0.2,
      observability: instrumentation_params(temp_file_path, 'call_transcription')
    )
    response&.text.to_s
  ensure
    FileUtils.rm_f(temp_file_path) if defined?(temp_file_path) && temp_file_path
  end

  def transcribe_file(file_path, temperature:, response_format: nil, timestamp_granularities: nil, observability: {})
    return transcribe_file_with_openrouter_chat(file_path, observability: observability) if openrouter_chat_transcription?

    if openrouter_transcription_endpoint?
      return transcribe_file_with_openrouter_transcription_endpoint(
        file_path,
        temperature: temperature,
        observability: observability
      )
    end

    options = {
      model: model,
      temperature: temperature,
      prompt: account.captain_audio_transcription_prompt,
      observability: observability.merge(provider: 'openrouter')
    }
    options[:response_format] = response_format if response_format.present?
    options[:timestamp_granularities] = timestamp_granularities if timestamp_granularities.present?

    instrument_audio_transcription(observability) do
      Llm::Runtime.transcribe(
        feature: :audio_transcription,
        account: account,
        model: model,
        input: file_path,
        observability: options.delete(:observability),
        options: options.except(:model)
      )
    end
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

  def transcribe_file_with_openrouter_chat(file_path, observability: {})
    provider_file_path = Llm::OpenRouterAudioInput.normalize_for_chat(
      file_path,
      logger_context: { account_id: account.id, call_id: call.id }
    )
    response = instrument_audio_transcription(observability) do
      Llm::Runtime.chat(
        feature: :audio_transcription,
        account: account,
        model: model,
        messages: [
          {
            role: 'user',
            content: RubyLLM::Content.new(openrouter_transcription_prompt, [provider_file_path])
          }
        ],
        observability: observability.merge(provider: 'openrouter'),
        options: { temperature: 0 }
      )
    end

    TranscriptionResult.new(text: response&.content.to_s, segments: [])
  ensure
    FileUtils.rm_f(provider_file_path) if provider_file_path.present? && provider_file_path != file_path
  end

  def transcribe_file_with_openrouter_transcription_endpoint(file_path, temperature:, observability: {})
    provider_file_path = Llm::OpenRouterAudioInput.normalize_for_transcription(
      file_path,
      logger_context: { account_id: account.id, call_id: call.id }
    )
    Llm::Runtime.transcribe(
      feature: :audio_transcription,
      account: account,
      model: model,
      input: provider_file_path,
      observability: observability.merge(provider: 'openrouter'),
      options: { temperature: temperature, prompt: account.captain_audio_transcription_prompt }
    )
  ensure
    FileUtils.rm_f(provider_file_path) if provider_file_path.present? && provider_file_path != file_path
  end

  def openrouter_transcription_prompt
    [
      'Transcribe the attached call recording accurately. Return only the transcript text, without markdown or commentary.',
      'If speaker roles are clear, label them as Клиент and Оператор.',
      account.captain_audio_transcription_prompt.presence
    ].compact.join("\n")
  end

  def instrumentation_params(file_path, runtime_mode)
    {
      span_name: 'llm.audio.transcription',
      provider: Llm::Config.provider_for_model(model, account: account),
      model: model,
      account: account,
      account_id: account.id,
      runtime_mode: runtime_mode,
      input: { file_name: File.basename(file_path.to_s) }
    }
  end

  def llm_feature_key
    'audio_transcription'
  end

  def llm_model_account
    account
  end

  def fetch_combined_recording
    blob = call.recording.blob
    temp_dir = Rails.root.join('tmp/uploads/call-transcriptions')
    FileUtils.mkdir_p(temp_dir)

    extension = extension_from_content_type(blob.content_type)
    temp_file_path = File.join(temp_dir, "#{blob.key}.#{extension}")

    File.open(temp_file_path, 'wb') do |file|
      blob.open { |blob_file| IO.copy_stream(blob_file, file) }
    end

    temp_file_path
  end

  def format_ts(seconds)
    total = seconds.to_i
    mins = total / 60
    secs = total % 60
    format('%<mins>02d:%<secs>02d', mins: mins, secs: secs)
  end

  def update_call_and_message(transcribed_text)
    return if transcribed_text.blank?

    call.update!(transcript: transcribed_text)
    account.increment_response_usage

    message = call.message
    return unless message

    data = (message.content_attributes || {}).dup
    data['data'] ||= {}
    data['data']['transcript'] = transcribed_text
    data['data']['recording_url'] = call.recording_url
    message.update!(content_attributes: data)
  end

  def extension_from_content_type(content_type)
    subtype = content_type.to_s.downcase.split(';').first.to_s.split('/').last.to_s
    { 'webm' => 'webm', 'ogg' => 'ogg', 'x-m4a' => 'm4a', 'x-wav' => 'wav', 'mpeg' => 'mp3' }.fetch(subtype, 'webm')
  end
end
