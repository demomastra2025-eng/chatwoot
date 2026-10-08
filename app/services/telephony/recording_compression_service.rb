# frozen_string_literal: true

require 'open3'
require 'fileutils'
require 'securerandom'
require 'digest'

# Re-encodes a WAV call recording as a 64 kbps stereo MP3 and atomically updates references only
# after the new file has been decoded and validated. The original remains available for 30 days.
# Keep conversion, validation, atomic publication and rollback together so references never point at unverified media.
class Telephony::RecordingCompressionService
  CompressionError = Class.new(StandardError)
  DurationDriftError = Class.new(StandardError)

  TARGET_BITRATE = '64k'
  TARGET_SAMPLE_RATE = 32_000
  MAX_DURATION_DRIFT_SECONDS = 1.0
  TIMEOUT_SECONDS = 600
  ORIGINAL_RETENTION_DAYS = 30
  SUPPORTED_EXTENSIONS = %w[.wav .wave .pcm].freeze
  Compressed = Struct.new(:temp_path, :target_path, :storage_key, :byte_size, :duration, :original_byte_size)

  def self.compress!(call_session: nil, storage_key: nil)
    new(call_session: call_session, storage_key: storage_key).perform!
  end

  def self.compress(call_session: nil, storage_key: nil)
    new(call_session: call_session, storage_key: storage_key).perform
  end

  def initialize(call_session: nil, storage_key: nil)
    @call_session = call_session
    @storage_key = storage_key || call_session&.recording_ref
  end

  def perform
    perform!
  rescue StandardError => e
    Rails.logger.warn("[RecordingCompressionService] Failed account=#{call_session&.account_id} " \
                      "session=#{call_session&.id} key_digest=#{key_digest} error=#{e.class.name}")
    { success: false, error: e.class.name }
  end

  # Conversion requires a persisted session, a fresh reference check, tenant path validation and format gates.
  # rubocop:disable Metrics/CyclomaticComplexity
  def perform!
    return { skipped: true, reason: :blank_storage_key } if storage_key.blank?

    session = call_session || find_call_session
    raise CompressionError, 'A persisted call session is required to switch recording references' unless session

    @call_session = session

    Storage::RecordingLock.synchronize(account_id: session.account_id, storage_keys: [storage_key]) do
      session.reload
      return { skipped: true, reason: :recording_reference_changed } unless session.recording_ref == storage_key

      source_path = Storage::RecordingPaths.resolve(storage_key, account_id: session.account_id)
      return { skipped: true, reason: :file_not_found } unless source_path
      return { skipped: true, reason: :already_mp3 } if source_path.extname.casecmp?('.mp3')
      return { skipped: true, reason: :unsupported_ext } unless SUPPORTED_EXTENSIONS.include?(source_path.extname.downcase)

      compress_file!(source_path)
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  private

  attr_reader :storage_key, :call_session

  def key_digest
    Digest::SHA256.hexdigest(storage_key.to_s).first(12)
  end

  # rubocop:disable Metrics/MethodLength
  def compress_file!(source_path)
    orig_size = File.size(source_path)
    orig_duration = probe_duration(source_path)

    temp_path = Pathname.new("#{source_path}.compressing_#{SecureRandom.hex(4)}.mp3")
    target_storage_key = storage_key.sub(/\.(wav|wave|pcm)\z/i, '.mp3')

    begin
      execute_ffmpeg!(source_path, temp_path)
      validate_output_file!(temp_path)
      validate_readability!(temp_path)
      comp_duration = probe_duration(temp_path)
      validate_duration_drift!(orig_duration, comp_duration)

      target_path = source_path.sub_ext('.mp3')
      raise CompressionError, 'Compressed output already exists' if target_path.exist?

      compressed = Compressed.new(temp_path, target_path, target_storage_key, File.size(temp_path), comp_duration, orig_size)
      swap_recording!(compressed)

      {
        success: true,
        original_bytes: orig_size,
        compressed_bytes: compressed.byte_size,
        # Physical quota still includes both copies for the 30-day recovery window.
        freed_bytes: 0,
        retained_original_bytes: orig_size,
        retained_original_expires_at: ORIGINAL_RETENTION_DAYS.days.from_now.iso8601,
        original_storage_key: storage_key,
        new_storage_key: target_storage_key,
        duration: comp_duration
      }
    ensure
      FileUtils.rm_f(temp_path)
    end
  end
  # rubocop:enable Metrics/MethodLength

  # Publish first, then atomically switch the database. Keep the original file untouched for recovery.
  def swap_recording!(compressed)
    File.link(compressed.temp_path, compressed.target_path)
    published_identity = File.stat(compressed.target_path).then { |stat| [stat.dev, stat.ino] }
    File.unlink(compressed.temp_path)

    session = update_database_records!(compressed)
    refresh_storage_breakdown(session)
  rescue Errno::EEXIST
    raise CompressionError, 'Compressed output already exists'
  rescue StandardError
    unlink_published_file_if_owned(compressed.target_path, published_identity)
    raise
  end

  def unlink_published_file_if_owned(path, identity)
    return unless identity && File.exist?(path)

    stat = File.stat(path)
    File.unlink(path) if identity == [stat.dev, stat.ino]
  rescue Errno::ENOENT
    nil
  end

  def execute_ffmpeg!(source_path, temp_path)
    cmd = [
      'ffmpeg', '-nostdin', '-loglevel', 'error', '-y',
      '-i', source_path.to_s,
      '-vn',
      '-ar', TARGET_SAMPLE_RATE.to_s,
      '-ac', '2',
      '-b:a', TARGET_BITRATE,
      '-f', 'mp3',
      temp_path.to_s
    ]

    _stdout, stderr, status = run_command(cmd)
    return if status.success?

    raise CompressionError, "ffmpeg exited with #{status.exitstatus}: #{stderr.lines.last(3).join(' ').strip}"
  end

  def validate_output_file!(temp_path)
    raise CompressionError, 'Output compressed file does not exist' unless File.file?(temp_path)
    raise CompressionError, 'Output compressed file is empty' if File.empty?(temp_path)
  end

  def validate_duration_drift!(orig_dur, comp_dur)
    unless orig_dur.finite? && comp_dur.finite? && orig_dur.positive? && comp_dur.positive?
      raise DurationDriftError,
            'Could not verify input and output durations'
    end

    drift = (comp_dur - orig_dur).abs
    return if drift <= MAX_DURATION_DRIFT_SECONDS

    raise DurationDriftError, "Duration drift #{drift.round(3)}s exceeds #{MAX_DURATION_DRIFT_SECONDS}s"
  end

  def probe_duration(file_path)
    cmd = [
      'ffprobe', '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'default=noprint_wrappers=1:nokey=1',
      file_path.to_s
    ]

    stdout, stderr, status = run_command(cmd)
    raise CompressionError, "ffprobe failed: #{stderr.lines.last(3).join(' ').strip}" unless status.success?

    duration = Float(stdout.strip)
    raise CompressionError, 'ffprobe returned an invalid duration' unless duration.finite? && duration.positive?

    duration
  rescue ArgumentError, TypeError => e
    raise CompressionError, "Could not read media duration: #{e.message}"
  end

  def validate_readability!(file_path)
    cmd = ['ffmpeg', '-nostdin', '-v', 'error', '-i', file_path.to_s, '-f', 'null', '-']
    _stdout, stderr, status = run_command(cmd)
    return if status.success?

    raise CompressionError, "Compressed output could not be decoded: #{stderr.lines.last(3).join(' ').strip}"
  end

  # Runs an external command without a shell and kills it when it exceeds TIMEOUT_SECONDS, so a stuck
  # ffmpeg can never occupy a worker thread forever.
  def run_command(cmd)
    Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thread|
      stdin.close
      out_reader = Thread.new { stdout.read }
      err_reader = Thread.new { stderr.read }

      unless wait_thread.join(TIMEOUT_SECONDS)
        kill_process(wait_thread.pid)
        wait_thread.join
        raise CompressionError, "#{cmd.first} timed out after #{TIMEOUT_SECONDS}s"
      end

      [out_reader.value, err_reader.value, wait_thread.value]
    end
  end

  def kill_process(pid)
    Process.kill('KILL', pid)
  rescue Errno::ESRCH
    nil
  end

  # Everything the database knows about the recording moves to the new file in one transaction. Errors
  # are not swallowed: the caller must know that the original may not be removed.
  def update_database_records!(compressed)
    session = call_session || find_call_session
    raise CompressionError, 'Call session not found for recording reference' unless session

    Telephony::RecordingReferenceUpdater.new(
      session: session, old_key: storage_key, compressed: compressed
    ).perform!
  end

  def refresh_storage_breakdown(session)
    session&.account&.storage_breakdown(force_refresh: true)
  rescue StandardError => e
    Rails.logger.warn("[RecordingCompressionService] Storage breakdown refresh failed account=#{session&.account_id} " \
                      "session=#{session&.id} key_digest=#{key_digest} error=#{e.class.name}")
  end

  def find_call_session
    return unless defined?(Telephony::CallSession) && Telephony::CallSession.table_exists?

    relation = Telephony::CallSession.where(recording_ref: storage_key)
    relation = relation.where(account_id: call_session.account_id) if call_session
    relation.first
  end
end
