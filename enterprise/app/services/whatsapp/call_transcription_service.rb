class Whatsapp::CallTranscriptionService < Llm::BaseAiService
  include Integrations::LlmInstrumentation

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
    @transcription_timings.measure(:persistence) { update_call_and_message(transcribed_text) }
    { success: true, transcript: transcribed_text }
  rescue RubyLLM::UnauthorizedError, Faraday::UnauthorizedError
    Rails.logger.warn('[WHATSAPP CALL] Skipping transcription: LLM transcription provider configuration is invalid (401)')
    { error: 'LLM transcription provider configuration is invalid' }
  end

  private

  def can_transcribe?
    account.call_transcriptions_enabled? && account.captain_quota_available?
  end

  def transcribe_audio
    @transcription_timings = Llm::TranscriptionTimings.new(source: 'whatsapp_call')
    @transcription_timings.measure(:model_selection) { model }
    transcribe_combined
  end

  def transcribe_combined
    temp_file_path = nil
    provider_file_path = nil
    @transcription_timings.measure(:file_preparation) do
      temp_file_path = fetch_combined_recording
      provider_file_path = Llm::OpenRouterAudioInput.normalize_for_transcription(temp_file_path)
    end
    response = transcribe_file(provider_file_path)
    response&.text.to_s
  ensure
    FileUtils.rm_f(temp_file_path) if temp_file_path.present?
    FileUtils.rm_f(provider_file_path) if provider_file_path.present? && provider_file_path != temp_file_path
  end

  def transcribe_file(file_path)
    observability = instrumentation_params(file_path, 'call_transcription')
    @transcription_timings.measure(:provider_request) do
      instrument_audio_transcription(observability) do
        Llm::Runtime.transcribe(
          feature: :audio_transcription,
          account: account,
          model: model,
          input: file_path,
          observability: observability.merge(provider: 'openrouter'),
          options: { temperature: 0.2, prompt: account.captain_audio_transcription_prompt,
                     stage_timings: @transcription_timings }
        )
      end
    end
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
