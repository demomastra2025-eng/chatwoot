# frozen_string_literal: true

require 'digest'
require 'fileutils'

# rubocop:disable Metrics/ClassLength
class Telephony::StoredRecordingReadyService
  SUPPORTED_RECORDED_BY = %w[janus browser pipecat].freeze
  SUPPORTED_LAYOUTS = %w[mixed_mono mono mixed_stereo stereo dual_channel].freeze
  DEFAULT_CONTENT_TYPE = 'audio/wav'

  def initialize(payload:, headers: {})
    @payload = payload.deep_stringify_keys
    @headers = headers.deep_stringify_keys
  end

  def perform
    validate!
    if recording_already_stored?
      sync_voice_message_recording!(call_session)
      return duplicate_response
    end

    updated_call_session = Telephony::EventsIngestionService.new(payload: recording_ready_payload).perform
    sync_voice_message_recording!(updated_call_session)
    response_payload(updated_call_session, status: 'ok')
  end

  private

  attr_reader :payload, :headers

  def sync_voice_message_recording!(session)
    Telephony::VoiceMessageRecordingSyncService.new(call_session: session).perform
  end

  def validate!
    validate_required_payload!
    validate_supported_values!
    validate_storage_key!
    validate_call_session!
    validate_file_integrity!
  end

  def validate_required_payload!
    required_payload_values.each do |value, field|
      require_value!(value, field)
    end
  end

  def required_payload_values
    [
      [call_ref, 'call_ref'],
      [storage_key, 'storage_key'],
      [sha256, 'sha256'],
      [size_bytes, 'size_bytes'],
      [duration_sec, 'duration_sec']
    ]
  end

  def validate_supported_values!
    raise_error!('UNSUPPORTED_RECORDED_BY', 'recorded_by is not supported') unless SUPPORTED_RECORDED_BY.include?(recorded_by)
    raise_error!('UNSUPPORTED_RECORDING_LAYOUT', 'layout is not supported') unless layout.blank? || SUPPORTED_LAYOUTS.include?(layout)
  end

  def validate_storage_key!
    raise_error!('INVALID_STORAGE_KEY', 'storage_key must be under voice-recordings/') unless storage_key.start_with?('voice-recordings/')
  end

  def validate_call_session!
    raise_error!('CALL_SESSION_NOT_FOUND', 'Unable to resolve call session for recording', status: :not_found) if call_session.blank?
    raise_error!('CONVERSATION_NOT_FOUND', 'Call session is not attached to a conversation', status: :not_found) if call_session.conversation.blank?
  end

  def validate_file_integrity!
    raise_error!('RECORDING_FILE_NOT_FOUND', 'recording file was not found', status: :not_found) unless File.file?(recording_path)
    raise_error!('RECORDING_SIZE_MISMATCH', 'recording size does not match payload') unless actual_size_bytes == size_bytes
    raise_error!('RECORDING_CHECKSUM_MISMATCH', 'recording checksum does not match payload') unless actual_sha256.casecmp?(sha256)
  end

  def require_value!(value, field)
    return if value.present?

    raise_error!('REQUIRED_FIELD_MISSING', "#{field} is required")
  end

  def raise_error!(code, message, status: :unprocessable_content)
    raise Telephony::Error.new(code: code, message: message, status: status)
  end

  def recording_ready_payload
    recording_event_payload
      .merge(recording_file_payload)
      .merge(recording_details_payload)
      .merge(metadata: recording_metadata)
      .compact
  end

  def recording_event_payload
    {
      'event' => 'recording_ready',
      'event_key' => event_key,
      'call_ref' => call_session.external_call_ref,
      'account_id' => call_session.account_id,
      'source_id' => "voice_call:#{call_session.external_call_ref}",
      'provider' => call_session.provider,
      'provider_call_id' => payload_value('provider_call_id', 'providerCallId') || call_session.provider_call_sid,
      'media_session_ref' => payload_value('media_session_ref', 'mediaSessionRef'),
      'inbox_id' => payload_value('inbox_id', 'inboxId') || call_session.inbox_id
    }
  end

  def recording_file_payload
    {
      'duration_seconds' => duration_sec,
      'duration_ms' => duration_ms,
      'recording_ref' => storage_key,
      'storage_key' => storage_key,
      'byte_size' => actual_size_bytes,
      'content_type' => content_type,
      'sha256' => actual_sha256
    }
  end

  def recording_details_payload
    {
      'layout' => layout,
      'mode' => mode,
      'recorded_by' => recorded_by,
      'channels' => channels,
      'channel_layout' => channel_layout,
      'channel_map' => channel_map,
      'degraded' => degraded,
      'missing_direction' => missing_direction
    }
  end

  def recording_metadata
    {
      'recording_import' => {
        'source' => "#{recorded_by}_stored_file",
        'event_key' => event_key,
        'recorded_by' => recorded_by,
        'layout' => layout,
        'mode' => mode
      }.compact,
      'recording' => {
        'writer' => payload_value('writer') || "#{recorded_by}_postprocessor",
        'storage_provider' => 'local'
      }
    }
  end

  def response_payload(session, status:)
    {
      status: status,
      call_ref: session.external_call_ref,
      source_id: "voice_call:#{session.external_call_ref}",
      conversation_id: session.conversation&.display_id,
      conversation_db_id: session.conversation_id,
      message_id: session.exact_voice_message&.id,
      recording_ref: storage_key,
      storage_key: storage_key
    }.compact
  end

  def duplicate_response
    response_payload(call_session, status: 'duplicate')
  end

  def recording_already_stored?
    recording = call_session.metadata.to_h['recording']
    return false unless recording.is_a?(Hash)

    recording['sha256'].to_s.casecmp?(sha256) && recording['storage_key'].present?
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

  def recording_path
    @recording_path ||= begin
      storage_root = recording_storage_root
      path = storage_root.join(storage_key).cleanpath
      validate_recording_path_containment!(path, storage_root)

      if File.exist?(path)
        real_path = Pathname.new(File.realpath(path.to_s))
        validate_recording_path_containment!(real_path, storage_root)

        real_path.to_s
      else
        path.to_s
      end
    end
  rescue Errno::EACCES, Errno::ELOOP
    raise_error!('INVALID_STORAGE_KEY', 'storage_key escapes storage root')
  end

  def recording_storage_root
    root = Rails.root.join('storage')
    FileUtils.mkdir_p(root)
    root.realpath
  end

  def validate_recording_path_containment!(path, storage_root)
    return if path.to_s.start_with?("#{storage_root}/")

    raise_error!('INVALID_STORAGE_KEY', 'storage_key escapes storage root')
  end

  def actual_size_bytes
    @actual_size_bytes ||= File.size(recording_path)
  end

  def actual_sha256
    @actual_sha256 ||= Digest::SHA256.file(recording_path).hexdigest
  end

  def account_id
    payload_value('account_id', 'accountId')
  end

  def call_ref
    payload_value('call_ref', 'callRef')
  end

  def storage_key
    payload_value('storage_key', 'storageKey', 'recording_ref', 'recordingRef').to_s
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

    milliseconds = duration_ms
    return (milliseconds.to_f / 1000.0).ceil if milliseconds.present?

    nil
  end

  def duration_ms
    payload_value('duration_ms', 'durationMs')&.to_i
  end

  def recorded_by
    payload_value('recorded_by', 'recordedBy').to_s.presence || 'janus'
  end

  def layout
    payload_value('layout').to_s.presence || 'mixed_mono'
  end

  def mode
    payload_value('mode').to_s.presence || 'operator'
  end

  def content_type
    payload_value('content_type', 'contentType', 'mime_type', 'mimeType').to_s.presence || DEFAULT_CONTENT_TYPE
  end

  def channels
    payload_value('channels')&.to_i
  end

  def channel_layout
    payload_value('channel_layout', 'channelLayout')
  end

  def channel_map
    payload_value('channel_map', 'channelMap')
  end

  def degraded
    value = payload_value('degraded', 'recording_degraded', 'recordingDegraded')
    return if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def missing_direction
    payload_value('missing_direction', 'missingDirection')
  end

  def event_key
    payload_value('event_key', 'eventKey', 'idempotency_key', 'idempotencyKey') ||
      headers['idempotency_key'] ||
      "recording_stored:#{account_id || 'global'}:#{call_ref}:#{sha256}"
  end

  def payload_value(*keys)
    keys.each do |key|
      value = payload[key.to_s]
      return value if value.present?
    end
    nil
  end
end
# rubocop:enable Metrics/ClassLength
