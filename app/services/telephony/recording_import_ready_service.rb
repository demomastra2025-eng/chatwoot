class Telephony::RecordingImportReadyService # rubocop:disable Metrics/ClassLength
  REQUIRED_MODE = 'operator_direct_bridge'.freeze
  REQUIRED_RECORDED_BY = 'fonoster'.freeze
  REQUIRED_LAYOUT = 'mixed_mono'.freeze
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
    require_value!(account_id, 'account_id')
    require_value!(call_ref, 'call_ref')
    require_value!(source_id, 'source_id')
    require_value!(download_url, 'download_url')
    require_value!(sha256, 'sha256')
    require_value!(payload_value('size_bytes', 'sizeBytes'), 'size_bytes')
    require_value!(payload_value('duration_sec', 'durationSec', 'duration_seconds', 'durationSeconds'), 'duration_sec')

    raise_error!('SOURCE_ID_MISMATCH', 'source_id must be voice_call:<call_ref>') unless source_id == expected_source_id
    raise_error!('UNSUPPORTED_RECORDING_MODE', 'Only operator_direct_bridge recording import is accepted') unless mode == REQUIRED_MODE
    raise_error!('UNSUPPORTED_RECORDED_BY', 'recorded_by must be fonoster') unless recorded_by == REQUIRED_RECORDED_BY
    raise_error!('UNSUPPORTED_RECORDING_LAYOUT', 'layout must be mixed_mono') unless layout == REQUIRED_LAYOUT
    raise_error!('AI_RECORDING_IMPORT_REJECTED', 'AI recordings must be written by OneLink runtime, not imported from Fonoster') if ai_app_ref?
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
      'event_key' => event_key,
      'source_id' => expected_source_id,
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
    @call_session ||= account&.telephony_call_sessions&.find_by(external_call_ref: call_ref)
  end

  def account
    @account ||= Account.find_by(id: account_id)
  end

  def account_id
    payload_value('account_id', 'accountId')
  end

  def call_ref
    payload_value('call_ref', 'callRef')
  end

  def source_id
    payload_value('source_id', 'sourceId')
  end

  def expected_source_id
    "voice_call:#{call_ref}"
  end

  def download_url
    payload_value('download_url', 'downloadUrl')
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
    payload_value('size_bytes', 'sizeBytes').to_i
  end

  def duration_sec
    payload_value('duration_sec', 'durationSec', 'duration_seconds', 'durationSeconds').to_i
  end

  def mode
    payload_value('mode').to_s
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
    headers['idempotency_key'].presence || payload_value('idempotency_key', 'idempotencyKey') ||
      "recording_ready:#{account_id}:#{call_ref}:#{sha256}"
  end

  def payload_value(*keys)
    keys.each do |key|
      value = payload[key.to_s]
      return value if value.present?
    end

    nil
  end
end
