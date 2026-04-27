class Whatsapp::CallTranscriptionService < Llm::BaseAiService
  include Integrations::LlmInstrumentation

  WHISPER_MODEL = 'whisper-1'.freeze

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
  rescue Faraday::UnauthorizedError
    Rails.logger.warn('[WHATSAPP CALL] Skipping transcription: OpenAI configuration is invalid (401)')
    { error: 'OpenAI configuration is invalid' }
  end

  private

  def can_transcribe?
    account.feature_enabled?('captain_integration') && account.captain_quota_available?
  end

  # Transcribe per-direction recordings separately when possible so lines can
  # be attributed to Customer vs Agent. Falls back to the combined recording
  # if the media server isn't available or per-side files are missing.
  def transcribe_audio
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
    options = {
      context: llm_context,
      model: WHISPER_MODEL,
      temperature: temperature,
      observability: observability
    }
    options[:response_format] = response_format if response_format.present?
    options[:timestamp_granularities] = timestamp_granularities if timestamp_granularities.present?

    instrument_audio_transcription(observability) do
      Llm::ApiClient.transcribe(file_path, **options)
    end
  end

  def llm_context
    Llm::Config.with_api_key(api_key, api_base: api_base) { |context| return context }
  end

  def instrumentation_params(file_path, runtime_mode)
    {
      span_name: 'llm.audio.transcription',
      provider: 'openai',
      model: WHISPER_MODEL,
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

  def api_key
    system_api_key.presence || openai_hook&.settings&.dig('api_key')
  end

  def api_base
    Llm::Config.api_base
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
