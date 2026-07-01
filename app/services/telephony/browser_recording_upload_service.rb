# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'securerandom'

class Telephony::BrowserRecordingUploadService
  BROWSER_RECORDING_FALLBACK_PROVIDERS = %w[asterisk_analog sipuni binotel].freeze
  DEFAULT_MAX_BYTES = 100.megabytes
  AUDIO_CONTENT_TYPES = {
    'audio/webm' => '.webm',
    'audio/ogg' => '.ogg',
    'audio/wav' => '.wav',
    'audio/x-wav' => '.wav',
    'audio/mpeg' => '.mp3',
    'audio/mp4' => '.m4a',
    'audio/aac' => '.aac'
  }.freeze
  EXTENSION_CONTENT_TYPES = AUDIO_CONTENT_TYPES.invert.freeze
  GENERIC_CONTENT_TYPES = %w[application/octet-stream binary/octet-stream].freeze

  StoredRecording = Data.define(:storage_key, :path, :byte_size, :content_type, :sha256)
  Result = Data.define(:call_session, :storage_key, :path, :byte_size, :content_type, :sha256)

  def self.perform!(...)
    new(...).perform!
  end

  def initialize(call_session:, recording:, duration_ms: nil, duration_seconds: nil)
    @call_session = call_session
    @recording = recording
    @duration_ms = positive_integer(duration_ms)
    @duration_seconds = positive_integer(duration_seconds)
  end

  def perform!
    validate!

    stored_recording = persist_recording!
    updated_call_session = ingest_recording_ready!(stored_recording)

    Result.new(
      call_session: updated_call_session || call_session.reload,
      storage_key: stored_recording.storage_key,
      path: stored_recording.path,
      byte_size: stored_recording.byte_size,
      content_type: stored_recording.content_type,
      sha256: stored_recording.sha256
    )
  end

  private

  attr_reader :call_session, :recording, :duration_ms, :duration_seconds

  def validate!
    raise_error('RECORDING_FILE_REQUIRED', 'recording file is required') if recording.blank?
    return if browser_recording_fallback_provider?

    raise_error('RECORDING_UPLOAD_UNSUPPORTED_PROVIDER', 'browser recording upload is not supported for this provider')
  end

  def browser_recording_fallback_provider?
    BROWSER_RECORDING_FALLBACK_PROVIDERS.include?(call_session.provider.to_s)
  end

  def persist_recording!
    content_type = recording_content_type
    extension = AUDIO_CONTENT_TYPES.fetch(content_type)
    tmp_path = storage_root.join("browser-recording-#{SecureRandom.hex(12)}.tmp")
    digest = Digest::SHA256.new
    byte_size = write_tmp_recording!(tmp_path, digest)
    sha256 = digest.hexdigest
    storage_key = storage_key_for(sha256, extension)
    final_path = move_recording_to_storage!(tmp_path, storage_key)

    StoredRecording.new(
      storage_key: storage_key,
      path: final_path.to_s,
      byte_size: byte_size,
      content_type: content_type,
      sha256: sha256
    )
  ensure
    FileUtils.rm_f(tmp_path) if defined?(tmp_path) && tmp_path.present?
  end

  def move_recording_to_storage!(tmp_path, storage_key)
    final_path = recording_path(storage_key)
    raise_error('RECORDING_STORAGE_PATH_INVALID', 'recording storage path is invalid') if final_path.blank?

    FileUtils.mkdir_p(final_path.dirname)
    FileUtils.mv(tmp_path, final_path) unless File.file?(final_path)
    final_path
  end

  def write_tmp_recording!(tmp_path, digest)
    byte_size = 0
    rewind_recording!
    File.open(tmp_path, 'wb') do |file|
      while (chunk = recording.read(1.megabyte))
        byte_size += chunk.bytesize
        raise_error('RECORDING_FILE_TOO_LARGE', 'recording file is too large', status: :payload_too_large) if byte_size > max_bytes

        digest.update(chunk)
        file.write(chunk)
      end
    end
    raise_error('RECORDING_FILE_EMPTY', 'recording file is empty') if byte_size.zero?

    byte_size
  end

  def ingest_recording_ready!(stored_recording)
    Telephony::EventsIngestionService.new(
      payload: recording_ready_payload(stored_recording)
    ).perform
  end

  def recording_ready_payload(stored_recording)
    {
      account_id: call_session.account_id,
      call_ref: call_session.external_call_ref,
      provider: call_session.provider,
      event: 'recording_ready',
      event_key: "browser_recording:#{call_session.account_id}:#{call_session.id}:#{stored_recording.sha256}",
      occurred_at: Time.current.iso8601,
      recording_ref: stored_recording.storage_key,
      storage_key: stored_recording.storage_key,
      byte_size: stored_recording.byte_size,
      content_type: stored_recording.content_type,
      sha256: stored_recording.sha256,
      duration_ms: duration_ms,
      duration_seconds: resolved_duration_seconds,
      callee_leg_answered: call_session.direction == 'outbound',
      metadata: recording_metadata
    }.compact
  end

  def recording_metadata
    {
      source: 'browser_webphone_recording',
      recording: {
        writer: 'browser_janus_media_recorder',
        storage_provider: 'local',
        recorded_by: 'browser'
      }
    }
  end

  def resolved_duration_seconds
    duration_seconds || (duration_ms / 1000 if duration_ms.present?)
  end

  def storage_key_for(sha256, extension)
    "voice-recordings/#{call_session.provider}/#{call_session.account_id}/#{call_session.id}/#{sha256}#{extension}"
  end

  def recording_path(storage_key)
    path = storage_root.join(storage_key).cleanpath
    return unless path.to_s.start_with?("#{storage_root}/")

    path
  end

  def storage_root
    @storage_root ||= begin
      root = Rails.root.join('storage')
      FileUtils.mkdir_p(root)
      root.realpath
    end
  end

  def recording_content_type
    content_type = recording.content_type.to_s.split(';').first.to_s.downcase
    return content_type if AUDIO_CONTENT_TYPES.key?(content_type)

    extension = File.extname(recording.original_filename.to_s).downcase
    fallback_to_extension = content_type.blank? || GENERIC_CONTENT_TYPES.include?(content_type)
    return EXTENSION_CONTENT_TYPES[extension] if fallback_to_extension && EXTENSION_CONTENT_TYPES.key?(extension)

    raise_error('RECORDING_CONTENT_TYPE_UNSUPPORTED', 'recording content type is not supported')
  end

  def rewind_recording!
    recording.rewind if recording.respond_to?(:rewind)
  end

  def max_bytes
    (ENV.fetch('TELEPHONY_BROWSER_RECORDING_MAX_BYTES', nil).presence || DEFAULT_MAX_BYTES).to_i
  end

  def positive_integer(value)
    integer = value.to_i
    integer.positive? ? integer : nil
  end

  def raise_error(code, message, status: :unprocessable_content)
    raise Telephony::Error.new(code: code, message: message, status: status)
  end
end
