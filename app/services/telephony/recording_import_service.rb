require 'digest'
require 'fileutils'
require 'net/http'
require 'tempfile'
require 'uri'

class Telephony::RecordingImportService # rubocop:disable Metrics/ClassLength
  class RetryableError < StandardError; end
  class NonRetryableError < StandardError; end

  DEFAULT_MAX_BYTES = 100.megabytes
  DEFAULT_TIMEOUT_SECONDS = 60
  MAX_REDIRECTS = 3

  def initialize(payload:)
    @payload = payload.deep_stringify_keys
  end

  def perform
    validate!
    if recording_already_stored?
      sync_voice_message_recording!(call_session)
      return duplicate_response
    end

    Tempfile.create(["#{recording_source}-recording-import", '.wav'], binmode: true) do |file|
      actual = download_recording!(file)
      verify_recording!(actual)
      storage_key = persist_recording!(file)
      ingest_recording_ready!(storage_key: storage_key, byte_size: actual[:byte_size])
    end
  end

  private

  attr_reader :payload

  def validate! # rubocop:disable Metrics/AbcSize
    require_value!(account_id, 'account_id')
    require_value!(call_ref, 'call_ref')
    require_value!(download_url, 'download_url')
    require_value!(sha256, 'sha256')
    require_value!(size_bytes, 'size_bytes')
    require_value!(duration_sec, 'duration_sec')

    unless Telephony::RecordingImportDownloadPolicy.allowed?(parsed_download_url)
      raise_non_retryable!('download_url must be an allowed HTTPS recording URL')
    end
    raise_non_retryable!('Call session was not found') if call_session.blank?
    raise_non_retryable!('Call session is not attached to a conversation') if call_session.conversation.blank?
    raise_non_retryable!('source_id must be voice_call:<call_ref>') if source_id.present? && source_id != expected_source_id
  end

  def require_value!(value, field)
    return if value.present?

    raise_non_retryable!("#{field} is required")
  end

  def download_recording!(file, uri = parsed_download_url, redirects_left = MAX_REDIRECTS)
    raise_non_retryable!('Recording download redirect URL is not allowed') unless Telephony::RecordingImportDownloadPolicy.allowed?(uri)

    with_http_response(uri) do |response|
      return stream_success_response!(response, file) if response.is_a?(Net::HTTPSuccess)
      return follow_redirect!(file, uri, response, redirects_left) if response.is_a?(Net::HTTPRedirection)

      raise_retryable!("Recording download failed with HTTP #{response.code}") if response.is_a?(Net::HTTPServerError)

      raise_non_retryable!("Recording download failed with HTTP #{response.code}")
    end
  rescue Timeout::Error, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError, OpenSSL::SSL::SSLError => e
    raise_retryable!("Recording download failed: #{e.class.name}")
  end

  def follow_redirect!(file, uri, response, redirects_left)
    raise_retryable!('Too many redirects while downloading recording') if redirects_left <= 0

    location = response['location'].to_s
    raise_retryable!('Recording download redirect without Location header') if location.blank?

    download_recording!(file, URI.join(uri, location), redirects_left - 1)
  end

  def with_http_response(uri, &)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: timeout_seconds, read_timeout: timeout_seconds) do |http|
      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = 'OneLink-RecordingImport/1.0'
      http.request(request, &)
    end
  end

  def stream_success_response!(response, file)
    digest = Digest::SHA256.new
    bytes = 0

    response.read_body do |chunk|
      bytes += chunk.bytesize
      raise_non_retryable!('Recording file exceeds maximum allowed size') if bytes > max_bytes

      digest.update(chunk)
      file.write(chunk)
    end
    file.flush
    file.rewind

    { byte_size: bytes, sha256: digest.hexdigest }
  end

  def verify_recording!(actual)
    raise_non_retryable!("Recording size mismatch: expected #{size_bytes}, got #{actual[:byte_size]}") if actual[:byte_size] != size_bytes
    raise_non_retryable!('Recording checksum mismatch') unless actual[:sha256].casecmp?(sha256)
  end

  def persist_recording!(file)
    path = storage_path
    return storage_key if File.file?(path) && Digest::SHA256.file(path).hexdigest.casecmp?(sha256)

    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, file.read)
    storage_key
  end

  def ingest_recording_ready!(storage_key:, byte_size:)
    call_session = Telephony::EventsIngestionService.new(payload: ingestion_payload(storage_key: storage_key, byte_size: byte_size)).perform
    mark_import_stored!(call_session, storage_key)
    sync_voice_message_recording!(call_session)
    response_payload(call_session, status: 'ok', storage_key: storage_key)
  end

  def sync_voice_message_recording!(session)
    Telephony::VoiceMessageRecordingSyncService.new(call_session: session).perform
  end

  def mark_import_stored!(call_session, storage_key)
    call_session.with_lock do
      metadata = (call_session.reload.metadata || {}).deep_dup
      import = metadata['recording_import'].is_a?(Hash) ? metadata['recording_import'].deep_dup : {}
      metadata['recording_import'] = import.merge(
        'status' => 'stored',
        'stored_at' => Time.current.iso8601,
        'source' => recording_import_source,
        'download_host' => parsed_download_url.host,
        'recorded_by' => payload_value('recorded_by', 'recordedBy'),
        'layout' => payload_value('layout'),
        'mode' => payload_value('mode'),
        'storage_key' => storage_key,
        'sha256' => sha256,
        'event_key' => event_key
      ).compact
      call_session.update!(metadata: metadata)
    end
  end

  def ingestion_payload(storage_key:, byte_size:) # rubocop:disable Metrics/MethodLength
    {
      'event' => 'recording_ready',
      'event_key' => "#{event_key}:stored",
      'call_ref' => call_ref,
      'account_id' => account_id,
      'source_id' => expected_source_id,
      'provider_call_id' => payload_value('provider_call_id', 'providerCallId'),
      'media_session_ref' => payload_value('media_session_ref', 'mediaSessionRef'),
      'app_ref' => payload_value('app_ref', 'appRef'),
      'number_ref' => payload_value('number_ref', 'numberRef'),
      'inbox_id' => payload_value('inbox_id', 'inboxId'),
      'ingress_number' => payload_value('ingress_number', 'ingressNumber'),
      'caller_number' => payload_value('caller_number', 'callerNumber'),
      'started_at' => payload_value('started_at', 'startedAt'),
      'ended_at' => payload_value('ended_at', 'endedAt'),
      'duration_seconds' => duration_sec,
      'recording_ref' => storage_key,
      'storage_key' => storage_key,
      'byte_size' => byte_size,
      'content_type' => 'audio/wav',
      'sha256' => sha256,
      'metadata' => {
        'recording_import' => {
          'source' => recording_import_source,
          'event_key' => event_key,
          'download_host' => parsed_download_url.host,
          'recorded_by' => payload_value('recorded_by', 'recordedBy'),
          'layout' => payload_value('layout'),
          'mode' => payload_value('mode')
        }.compact
      }
    }.compact
  end

  def recording_import_source
    "#{recording_source}_download_url"
  end

  def duplicate_response
    response_payload(call_session, status: 'duplicate', storage_key: existing_recording_metadata['storage_key'])
  end

  def response_payload(call_session, status:, storage_key:)
    {
      status: status,
      call_ref: call_session.external_call_ref,
      source_id: expected_source_id,
      conversation_id: call_session.conversation&.display_id,
      conversation_db_id: call_session.conversation_id,
      message_id: call_session.logical_group_voice_message&.id,
      recording_ref: storage_key,
      storage_key: storage_key
    }.compact
  end

  def recording_already_stored?
    existing_recording_metadata['sha256'].to_s.casecmp?(sha256) && existing_recording_metadata['storage_key'].present?
  end

  def existing_recording_metadata
    @existing_recording_metadata ||= begin
      recording = call_session&.metadata.to_h['recording']
      recording.is_a?(Hash) ? recording : {}
    end
  end

  def storage_key
    @storage_key ||= "voice-recordings/#{recording_source}/#{account_id}/#{sanitized_call_ref}/#{sha256}.wav"
  end

  def recording_source
    source = payload_value('recorded_by', 'recordedBy').to_s.presence || 'provider'
    source.gsub(/[^a-zA-Z0-9._-]/, '_')
  end

  def storage_path
    storage_root = Rails.root.join('storage').cleanpath
    path = storage_root.join(storage_key).cleanpath
    raise_non_retryable!('Invalid recording storage path') unless path.to_s.start_with?("#{storage_root}/")

    path.to_s
  end

  def sanitized_call_ref
    call_ref.to_s.gsub(/[^a-zA-Z0-9._-]/, '_')
  end

  def max_bytes
    ENV.fetch('TELEPHONY_RECORDING_IMPORT_MAX_BYTES', DEFAULT_MAX_BYTES).to_i
  end

  def timeout_seconds
    ENV.fetch('TELEPHONY_RECORDING_IMPORT_TIMEOUT_SECONDS', DEFAULT_TIMEOUT_SECONDS).to_i
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

  def event_key
    payload_value('event_key', 'eventKey', 'idempotency_key', 'idempotencyKey') || "recording_ready:#{account_id}:#{call_ref}:#{sha256}"
  end

  def call_session
    @call_session ||= Account.find_by(id: account_id)&.telephony_call_sessions&.find_by(external_call_ref: call_ref)
  end

  def payload_value(*keys)
    keys.each do |key|
      value = payload[key.to_s]
      return value if value.present?
    end

    nil
  end

  def raise_retryable!(message)
    raise RetryableError, message
  end

  def raise_non_retryable!(message)
    raise NonRetryableError, message
  end
end
