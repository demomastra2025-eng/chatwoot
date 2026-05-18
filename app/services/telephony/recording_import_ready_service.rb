class Telephony::RecordingImportReadyService # rubocop:disable Metrics/ClassLength
  SUPPORTED_OPERATOR_MODES = %w[operator operator_direct_bridge operator_bridge inbound_operator outbound_operator].freeze
  REQUIRED_RECORDED_BY = 'fonoster'.freeze
  SUPPORTED_LAYOUTS = %w[mixed_mono mono mixed_stereo stereo dual_channel].freeze
  DEFAULT_BLOCKED_APP_REFS = %w[f2498e07-2bb5-45a1-8c8c-6fecdb4c791a].freeze

  def initialize(payload:, headers: {})
    @payload = payload.deep_stringify_keys
    @headers = headers.deep_stringify_keys
  end

  def perform
    validate!

    enqueued = false
    result = nil
    call_session.with_lock do
      call_session.reload
      result = duplicate_response if recording_already_stored?
      result ||= queued_response if import_already_queued?
      next if result.present?

      mark_import_queued!
      enqueued = true
      result = accepted_response
    end

    Telephony::RecordingImportJob.perform_later(job_payload) if enqueued
    result
  end

  private

  attr_reader :payload, :headers

  def validate! # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    require_value!(call_ref, 'call_ref')
    require_value!(download_url, 'download_url')
    require_value!(sha256, 'sha256')
    require_value!(payload_value('size_bytes', 'sizeBytes', 'byte_size', 'byteSize'), 'size_bytes')
    require_value!(payload_value('duration_sec', 'durationSec', 'duration_seconds', 'durationSeconds', 'duration_ms', 'durationMs'), 'duration_sec')

    raise_error!('SOURCE_ID_MISMATCH', 'source_id must be voice_call:<call_ref>') if raw_source_id.present? && raw_source_id != expected_source_id
    raise_error!('UNSUPPORTED_RECORDING_MODE', 'Only operator recording import is accepted') unless operator_mode?
    raise_error!('UNSUPPORTED_RECORDED_BY', 'recorded_by must be fonoster') unless recorded_by == REQUIRED_RECORDED_BY
    raise_error!('UNSUPPORTED_RECORDING_LAYOUT', 'layout is not supported') unless supported_layout?
    if ai_app_ref? || ai_mode?
      raise_error!('AI_RECORDING_IMPORT_REJECTED', 'AI recordings must be written by OneLink runtime, not imported from Fonoster')
    end
    unless Telephony::RecordingImportDownloadPolicy.allowed?(parsed_download_url)
      raise_error!('INVALID_DOWNLOAD_URL', 'download_url must be an allowed HTTPS recording URL')
    end
    raise_error!('CALL_SESSION_NOT_FOUND', 'Unable to resolve call session for recording import', status: :not_found) if call_session.blank?
    raise_error!('CONVERSATION_NOT_FOUND', 'Call session is not attached to a conversation', status: :not_found) if call_session.conversation.blank?
  end

  def require_value!(value, field)
    return if value.present?

    raise_error!('REQUIRED_FIELD_MISSING', "#{field} is required")
  end

  def raise_error!(code, message, status: :unprocessable_content)
    raise Telephony::Error.new(code: code, message: message, status: status)
  end

  def mark_import_queued!
    metadata = (call_session.metadata || {}).deep_dup
    metadata['recording_import'] = import_metadata.merge('status' => 'queued', 'queued_at' => Time.current.iso8601)
    call_session.update!(metadata: metadata)
  end

  def recording_already_stored?
    recording = call_session.metadata.to_h['recording']
    return false unless recording.is_a?(Hash)

    recording['sha256'].to_s.casecmp?(sha256) && recording['storage_key'].present?
  end

  def import_already_queued?
    import = call_session.metadata.to_h['recording_import']
    return false unless import.is_a?(Hash)

    import['event_key'] == event_key && import['sha256'].to_s.casecmp?(sha256) && import['status'] == 'queued'
  end

  def accepted_response
    response_payload.merge(status: 'accepted', duplicate: false)
  end

  def queued_response
    response_payload.merge(status: 'accepted', duplicate: true)
  end

  def duplicate_response
    response_payload.merge(status: 'duplicate', duplicate: true, recording_ref: call_session.recording_ref)
  end

  def response_payload
    {
      event_key: event_key,
      call_ref: call_session.external_call_ref,
      source_id: expected_source_id,
      conversation_id: call_session.conversation&.display_id,
      conversation_db_id: call_session.conversation_id,
      message_id: call_session.exact_voice_message&.id
    }.compact
  end

  def job_payload
    payload.merge(
      'account_id' => call_session.account_id,
      'call_ref' => call_session.external_call_ref,
      'event_key' => event_key,
      'source_id' => expected_source_id,
      'download_url' => download_url,
      'size_bytes' => size_bytes,
      'duration_sec' => duration_sec,
      'mode' => mode,
      'layout' => layout,
      'recorded_by' => recorded_by,
      'received_at' => Time.current.iso8601
    )
  end

  def import_metadata
    {
      'event_key' => event_key,
      'call_ref' => call_ref,
      'source_id' => expected_source_id,
      'sha256' => sha256,
      'size_bytes' => size_bytes,
      'duration_sec' => duration_sec,
      'download_host' => parsed_download_url&.host,
      'recorded_by' => recorded_by,
      'layout' => layout,
      'mode' => mode,
      'app_ref' => app_ref,
      'media_session_ref' => payload_value('media_session_ref', 'mediaSessionRef')
    }.compact
  end

  def call_session
    @call_session ||= begin
      scoped_session = Account.find_by(id: account_id)&.telephony_call_sessions&.find_by(external_call_ref: call_ref) if account_id.present?
      scoped_session || uniquely_resolved_call_session
    end
  end

  def uniquely_resolved_call_session
    return if account_id.present?

    matches = Telephony::CallSession.where(external_call_ref: call_ref).limit(2).to_a
    raise_error!('CALL_SESSION_AMBIGUOUS', 'call_ref matches more than one call session; account_id is required') if matches.size > 1

    matches.first
  end

  def account
    @account ||= if account_id.present?
                   Account.find_by(id: account_id)
                 else
                   call_session&.account
                 end
  end

  def account_id
    payload_value('account_id', 'accountId')
  end

  def call_ref
    payload_value('call_ref', 'callRef')
  end

  def source_id
    raw_source_id.presence || expected_source_id
  end

  def raw_source_id
    payload_value('source_id', 'sourceId')
  end

  def expected_source_id
    "voice_call:#{call_ref}"
  end

  def download_url
    payload_value('download_url', 'downloadUrl', 'recording_url', 'recordingUrl')
  end

  def parsed_download_url
    @parsed_download_url ||= begin
      uri = URI.parse(download_url.to_s)
      uri if uri.is_a?(URI::HTTP) && uri.host.present?
    rescue URI::InvalidURIError
      nil
    end
  end

  def sha256
    payload_value('sha256', 'checksum').to_s.downcase
  end

  def size_bytes
    payload_value('size_bytes', 'sizeBytes', 'byte_size', 'byteSize').to_i
  end

  def duration_sec
    seconds = payload_value('duration_sec', 'durationSec', 'duration_seconds', 'durationSeconds')
    return seconds.to_i if seconds.present?

    milliseconds = payload_value('duration_ms', 'durationMs')
    return (milliseconds.to_f / 1000.0).ceil if milliseconds.present?

    nil
  end

  def mode
    payload_value('mode').to_s.presence || 'operator'
  end

  def recorded_by
    payload_value('recorded_by', 'recordedBy').to_s
  end

  def layout
    payload_value('layout').to_s
  end

  def app_ref
    payload_value('app_ref', 'appRef').to_s
  end

  def operator_mode?
    SUPPORTED_OPERATOR_MODES.include?(mode)
  end

  def ai_mode?
    mode.start_with?('ai')
  end

  def supported_layout?
    layout.blank? || SUPPORTED_LAYOUTS.include?(layout)
  end

  def ai_app_ref?
    app_ref.present? && blocked_app_refs.include?(app_ref)
  end

  def blocked_app_refs
    @blocked_app_refs ||= ([
      ENV.fetch('ONELINK_AI_VOICE_APP_REF', nil),
      ENV.fetch('TELEPHONY_BRIDGE_ONELINK_AI_APP_REF', nil),
      ENV.fetch('TELEPHONY_BRIDGE_DEFAULT_AI_APP_REF', nil),
      ENV.fetch('TELEPHONY_BRIDGE_FONOSTER_AI_APP_REF', nil),
      ENV.fetch('TELEPHONY_RECORDING_IMPORT_BLOCKED_APP_REFS', nil)
    ].compact.flat_map { |value| value.to_s.split(',') } + DEFAULT_BLOCKED_APP_REFS).map(&:strip).reject(&:blank?).uniq
  end

  def event_key
    resolved_account_id = account_id.presence || call_session&.account_id
    headers['idempotency_key'].presence || payload_value('idempotency_key', 'idempotencyKey') ||
      "recording_ready:#{resolved_account_id}:#{call_ref}:#{sha256}"
  end

  def payload_value(*keys)
    keys.each do |key|
      value = payload[key.to_s]
      return value if value.present?
    end

    nil
  end
end
