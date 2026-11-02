# Existing transcription provider orchestration is intentionally retained in one service; this storage patch only adds safe metadata writes.
# rubocop:disable Metrics/ClassLength
class Telephony::CallRecordingTranscriptionService < Llm::BaseAiService
  include Integrations::LlmInstrumentation

  class RecordingNotFound < StandardError; end

  TranscriptionResult = Struct.new(:text, keyword_init: true)

  attr_reader :call_session, :account

  def initialize(call_session, force: false)
    @call_session = call_session
    @account = call_session.account
    @force = force
    super()
  end

  def perform
    return { error: 'Transcription not available' } unless can_transcribe?

    if cached_transcript.present? && !@force
      persist_cached_transcript!
      return { success: true, transcript: cached_transcript }
    end

    result = Telephony::CallTranscript.parse(transcribe_recording)
    transcript = result['text'].presence || result['summary']
    return { error: 'Empty transcript' } if transcript.blank?

    update_call_and_message!(result, source: 'audio_transcription')
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
    account.call_transcriptions_enabled? && account.call_analysis_quota_available?
  end

  def cached_transcript
    call_session.metadata&.dig('recording', 'transcription', 'text').presence ||
      ai_voice_runtime_transcript.presence ||
      voice_message&.content_attributes&.dig('data', 'transcript').presence
  end

  def persist_cached_transcript!
    return if recording_metadata.dig('transcription', 'status') == 'completed'

    update_call_and_message!(Telephony::CallTranscript.parse(cached_transcript), source: cached_transcript_source)
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
    speaker.to_s.in?(%w[caller customer contact user]) ? 'Клиент' : 'Сотрудник'
  end

  def transcribe_recording
    file_path, staged_remote_file = resolve_recording_file!
    provider_file_path = audio_file_path_for_provider(file_path)
    probe_audio!(file_path, provider_path: provider_file_path)
    response = if openrouter_chat_transcription?
                 transcribe_with_openrouter_chat(provider_file_path)
               else
                 transcribe_with_transcription_endpoint(provider_file_path)
               end

    format_transcription_response(response)
  ensure
    FileUtils.rm_f(provider_file_path) if provider_file_path.present? && provider_file_path != file_path
    FileUtils.rm_f(file_path) if staged_remote_file && file_path.present?
  end

  def probe_audio!(file_path, provider_path: file_path)
    @audio_probe = Telephony::CallTranscript.probe(file_path)
    if provider_path != file_path && @audio_probe['duration_seconds'].blank?
      @audio_probe = @audio_probe.merge(Telephony::CallTranscript.probe(provider_path))
    end
    return unless @audio_probe['channels'] == 2 && !openrouter_chat_transcription?

    @channel_activity = Telephony::CallTranscript.channel_activity(provider_path, duration_seconds: @audio_probe['duration_seconds'])
  end

  def format_transcription_response(response)
    segments = response.respond_to?(:segments) ? Array(response.segments) : []
    return response.respond_to?(:text) ? response.text.to_s : response.to_s if segments.empty?

    roles = [
      channel_role_label('channel_1', default: 'Operator').downcase,
      channel_role_label('channel_2', default: 'Client').downcase
    ]
    items = Telephony::CallTranscript.from_segments(segments, channel_activity: @channel_activity.to_h, roles: roles)
    enrich_segmented_transcript(items, response.text.to_s)
  end

  def enrich_segmented_transcript(items, fallback_text)
    dialogue = Telephony::CallTranscript.format(items).presence || fallback_text
    prompt = 'Analyze this clinic call transcript. Return ONLY JSON with summary (1-2 factual sentences in Russian), ' \
             'outcome (booked/rescheduled/cancelled/consultation/callback_requested/no_answer/other), and topics (1-5 Russian tags).'
    prompt += ' Also include transcript_items (speaker operator/client, timestamp, start_sec, text).' unless dual_channel_recording?
    chat = Llm::Runtime.chat(
      feature: :customer_notice, account: account,
      messages: [{ role: 'user', content: "#{prompt}\n\n#{dialogue}" }],
      options: { temperature: 0.1 }
    )
    parsed = Telephony::CallTranscript.decode(chat&.content.to_s)
    parsed['transcript_items'] = items if dual_channel_recording? || Array(parsed['transcript_items']).empty?
    parsed.to_json
  rescue StandardError
    { 'transcript_items' => items }.to_json
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
        options: { temperature: 0.2 }
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
        options: openrouter_chat_options
      )
    end

    TranscriptionResult.new(text: response&.content.to_s)
  end

  def openrouter_chat_options
    return { temperature: 0 } unless model.to_s.include?('gemini-3')

    { temperature: 0.1, params: { reasoning: { effort: 'minimal' } } }
  end

  def resolve_recording_file!
    local_path = local_recording_file_path
    return [local_path, false] if local_path.present?

    remote_path = stage_remote_recording_file
    return [remote_path, true] if remote_path.present?

    raise RecordingNotFound, 'Recording file could not be found'
  end

  def recording_file_path!
    path, = resolve_recording_file!
    path
  end

  def local_recording_file_path
    storage_key = validated_recording_storage_key!
    storage_root = Rails.root.join('storage').realpath
    candidate_storage_keys(storage_key).each do |candidate_key|
      resolved = validated_local_candidate_path(storage_root, candidate_key)
      return resolved if resolved.present?
    end

    nil
  rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
    nil
  end

  def validated_recording_storage_key!
    storage_key = recording_storage_key
    raise RecordingNotFound, 'Recording storage key is missing' if storage_key.blank?
    raise RecordingNotFound, 'Recording file could not be found' unless storage_key.start_with?('voice-recordings/')

    storage_key
  end

  def validated_local_candidate_path(storage_root, candidate_key)
    path = storage_root.join(candidate_key).cleanpath
    return unless path.to_s.start_with?("#{storage_root}/") && File.file?(path)

    real_path = Pathname.new(File.realpath(path.to_s))
    raise RecordingNotFound, 'Recording file could not be found' unless real_path.to_s.start_with?("#{storage_root}/")

    real_path.to_s
  end

  def stage_remote_recording_file
    storage_key = recording_storage_key
    return if storage_key.blank? || !storage_key.start_with?('voice-recordings/')

    candidate_storage_keys(storage_key).each do |candidate_key|
      bytes = Storage::VoiceRecordingRemoteStorage.download(candidate_key)
      next if bytes.blank?

      ext = File.extname(candidate_key).presence || '.mp3'
      tempfile = Tempfile.new(['call-recording-remote-', ext], binmode: true)
      tempfile.write(bytes)
      tempfile.close
      return tempfile.path
    end

    nil
  end

  def candidate_storage_keys(storage_key)
    keys = [storage_key]
    keys << storage_key.sub(/\.(wav|wave|pcm)\z/i, '.mp3') if storage_key.match?(/\.(wav|wave|pcm)\z/i)
    keys.uniq
  end

  def recording_storage_key
    recording_metadata['storage_key'].presence || recording_metadata['recording_ref'].presence || call_session.recording_ref.presence
  end

  def recording_metadata
    metadata = call_session.metadata
    recording = metadata.is_a?(Hash) ? metadata['recording'] : nil
    recording.is_a?(Hash) ? recording.deep_stringify_keys : {}
  end

  def update_call_and_message!(result, source:)
    transcript_ref = "call_recording_transcript:#{call_session.external_call_ref}"
    persist_call_transcript!(result, source, transcript_ref)

    # Message callbacks and competing voice-event writes can be slow. Do not keep the
    # call-session row locked while waiting for the message row or its callbacks.
    message = update_voice_message!(result, transcript_ref)
    refresh_call_contact_language!(message)
    message&.reload&.send_update_event
  end

  def refresh_call_contact_language!(message)
    target_contact = call_session.contact || message&.conversation&.contact
    return unless target_contact

    before_attrs = target_contact.additional_attributes.to_h
    Contacts::LanguageStatsService.refresh!(target_contact)
    target_contact.dispatch_shared_phone_update_event if target_contact.additional_attributes.to_h != before_attrs
  end

  def persist_call_transcript!(result, source, transcript_ref)
    billable_source = source.to_s == 'audio_transcription'
    call_session.with_lock do
      metadata = (call_session.reload.metadata || {}).deep_dup
      recording = metadata['recording'] ||= {}
      existing_billed_at = recording.dig('transcription', 'billed_at')
      recording['audio_probe'] = @audio_probe if @audio_probe.present?
      billed_at = transcription_billed_at(existing_billed_at, billable_source)
      recording['transcription'] = transcription_metadata(result, source, recording, billed_at: billed_at)
      call_session.update!(metadata: metadata, transcript_ref: transcript_ref)
      record_call_metering!(build_call_metering_payload(recording, metadata, result)) if billable_source && existing_billed_at.blank?
    end
  end

  def transcription_billed_at(existing, billable_source)
    existing || (Time.current.iso8601 if billable_source)
  end

  def build_call_metering_payload(recording, metadata, result)
    {
      duration_seconds: resolve_call_duration_seconds(recording, metadata),
      unanswered: unanswered_call?(result, metadata)
    }
  end

  def record_call_metering!(payload)
    return unless payload

    Accounts::MonthlyAiUsageService.new(account).record_call_analysis!(call: call_session, **payload)
  end

  def transcription_metadata(result, source, recording, billed_at: nil)
    payload = result.merge('status' => 'completed', 'source' => source, 'model' => model,
                           'channels' => @audio_probe&.dig('channels') || recording['channels'],
                           'completed_at' => Time.current.iso8601)
    payload['billed_at'] = billed_at if billed_at.present?
    payload
  end

  def resolve_call_duration_seconds(recording, metadata)
    @audio_probe&.dig('duration_seconds') ||
      recording.dig('audio_probe', 'duration_seconds') ||
      recording['duration_seconds'] ||
      metadata['duration_seconds'] ||
      call_session_duration_seconds
  end

  def call_session_duration_seconds
    return call_session.duration_seconds if call_session.respond_to?(:duration_seconds) && call_session.duration_seconds.present?
    return unless call_session.respond_to?(:answered_at) && call_session.respond_to?(:ended_at)
    return unless call_session.answered_at.present? && call_session.ended_at.present?

    call_session.ended_at - call_session.answered_at
  end

  def unanswered_call?(result, metadata)
    unanswered_statuses = %w[created ringing connecting missed unanswered no_answer busy failed canceled cancelled rejected]
    end_reason = call_session.respond_to?(:end_reason) ? call_session.end_reason.to_s : ''
    result['outcome'].to_s == 'no_answer' ||
      unanswered_statuses.include?(call_session.status.to_s) ||
      unanswered_statuses.include?(end_reason) ||
      %w[NO_ANSWER USER_BUSY ORIGINATOR_CANCEL].include?(metadata['hangup_cause'].to_s)
  end

  def update_voice_message!(result, transcript_ref)
    message = voice_message
    return unless message

    message.with_lock do
      message.reload
      attributes = normalized_content_attributes(message)
      attributes['data'] ||= {}
      attributes['data'].merge!(voice_transcript_data(result, transcript_ref))
      latest_recording = recording_metadata
      attributes['data']['recording'] = latest_recording if latest_recording.present?
      message.update!(content_attributes: attributes)
    end
    message
  end

  def voice_transcript_data(result, transcript_ref)
    { 'transcript_ref' => transcript_ref, 'transcript' => result['text'],
      'transcript_items' => result['transcript_items'], 'transcript_summary' => result['summary'],
      'transcript_outcome' => result['outcome'], 'transcript_topics' => result['topics'] }
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
      'Transcribe the attached clinic call recording accurately in the languages spoken (Russian, Kazakh, or mixed). ' \
      'Preserve code switching; do not translate. Ignore carrier IVR pre-roll ' \
      '("Сервисті жақсарту үшін жазамыз / Ведётся запись для улучшения сервиса"). ' \
      'If the recording has only carrier IVR pre-roll, ringback, or silence with no human conversation, return items: [], ' \
      'outcome: "no_answer", and a 1-sentence Russian summary stating that no conversation took place. ' \
      'Return ONLY valid compact JSON with summary in Russian (1-2 factual sentences), ' \
      'outcome (booked/rescheduled/cancelled/consultation/callback_requested/no_answer/other), 1-5 topics, ' \
      'and items ([[start_sec, "op"|"cl", "text"]]) or transcript_items (speaker operator/client, timestamp MM:SS, start_sec, text).',
      clinic_doctors_prompt,
      speaker_channel_prompt,
      account.captain_audio_transcription_prompt.presence
    ].compact.join("\n")
  end

  def clinic_doctors_prompt
    names = Scheduling::Resource.where(account_id: account.id).where.not(name: [nil, '']).distinct.limit(80).pluck(:name)
    return if names.empty?

    "Clinic doctors and specialists: #{names.join('; ')}."
  rescue StandardError
    nil
  end

  def speaker_channel_prompt
    unless dual_channel_recording?
      return 'For mono audio, infer Сотрудник (clinic representative who greets, answers questions or books visits) ' \
             'versus Клиент (patient/caller) from dialogue and acoustic cues. Include turn timestamps.'
    end

    channel_1_role = channel_role_label('channel_1', default: 'Operator')
    channel_2_role = channel_role_label('channel_2', default: 'Client')
    base = [
      'This is a 2-channel stereo call recording where each speaker is recorded on a separate channel:',
      "Channel 1 (Left channel) is #{channel_1_role}, and Channel 2 (Right channel) is #{channel_2_role}.",
      'Attribute each speaker consistently by voice and role throughout the call: "op" (operator / Сотрудник) is the clinic ' \
      'representative or receptionist who answers on behalf of the clinic, explains services/prices/doctors or books visits, ' \
      'and "cl" (client / Клиент) is the caller/patient.'
    ].join(' ')
    return base if @channel_activity.blank?

    "#{base} Activity windows in seconds, left=#{@channel_activity['0']}, right=#{@channel_activity['1']}."
  end

  def dual_channel_recording?
    return @audio_probe['channels'] == 2 if @audio_probe&.dig('channels').present?

    recording_metadata['layout'].to_s == 'dual_channel' ||
      recording_metadata['channel_layout'].to_s == 'stereo' ||
      recording_metadata['channels'].to_i == 2 ||
      recording_metadata['channel_map'].is_a?(Hash)
  end

  def channel_role_label(channel_key, default:)
    map = recording_metadata['channel_map'].to_h
    aliases = channel_key == 'channel_1' ? %w[channel_1 left FL c0 1] : %w[channel_2 right FR c1 2]
    role = aliases.filter_map { |key| map[key] }.first.to_s
    case role
    when 'user_audio', 'operator', 'agent'
      'Operator'
    when 'peer_audio', 'caller', 'customer', 'client'
      'Client'
    else
      default
    end
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
  # rubocop:enable Metrics/ClassLength
end
