# frozen_string_literal: true

# Owns only a private, short-lived copy, never the original recording or another tenant's file.
# Keep descriptor lifetime, boundary checks and guarded cleanup in the same ownership scope.
class Telephony::VoiceCoreRecordingSpool
  MAX_AUDIO_BYTES = 100.megabytes
  EXTENSIONS = %w[.wav .mp3 .ogg .m4a .flac].freeze

  attr_reader :job_id, :audio_filename

  def initialize(call_session)
    @call_session = call_session
    @job_id = SecureRandom.hex(16)
    @directories = []
    @directory_handles = []
  end

  def open
    prepare_directory!
    stage_recording!
    assert_boundaries!
    result = yield self
    assert_boundaries!
    result
  rescue Telephony::VoiceCoreClient::Error
    raise
  rescue StandardError
    raise Telephony::VoiceCoreClient::Error, 'staging_failed'
  ensure
    cleanup
  end

  private

  def storage_keys
    key = recording_storage_key
    raise Telephony::VoiceCoreClient::Error, 'invalid_recording_key' unless valid_key?(key)

    keys = [key]
    keys << key.sub(/\.(wav|wave|pcm)\z/i, '.mp3') if key.match?(/\.(wav|wave|pcm)\z/i)
    keys
  end

  def recording_storage_key
    recording = @call_session.metadata.to_h['recording'].to_h
    recording['storage_key'].presence || recording['recording_ref'].presence || @call_session.recording_ref
  end

  def valid_key?(key)
    return false unless key.is_a?(String) && key.exclude?("\0")

    Storage::RecordingMetadata.local_key(key, account_id: @call_session.account_id)&.start_with?('voice-recordings/') ||
      Storage::RecordingMetadata.legacy_basename?(key)
  end

  def spool_root!
    raw = ENV.fetch('ONELINK_VOICECORE_SPOOL_ROOT', '')
    raise Telephony::VoiceCoreClient::Error, 'invalid_configuration' unless raw.start_with?('/')

    root = Pathname.new(raw)
    if root == Pathname.new('/') || root.each_filename.any? { |part| %w[. ..].include?(part) }
      raise Telephony::VoiceCoreClient::Error, 'invalid_configuration'
    end

    current = safe_directory(Pathname.new('/'))
    root.each_filename do |part|
      current = current.join(part)
      safe_directory(current, private: current == root)
    end

    root
  end

  def prepare_directory!
    root = spool_root!
    account_root = safe_directory(root.join(@call_session.account_id.to_s), private: true)
    candidate = account_root.join(job_id)
    assert_boundaries!
    Dir.mkdir(candidate, 0o700)
    safe_directory(candidate, private: true)
    @directory = candidate
  end

  def safe_directory(path, private: false)
    assert_boundaries!
    begin
      Dir.mkdir(path, 0o700)
    rescue Errno::EEXIST
      # Existing entries are validated, never chmod/chowned into the trust boundary.
    end
    handle = File.open(path, File::RDONLY | File::NOFOLLOW)
    @directory_handles << handle
    stat = handle.stat
    valid = stat.directory? && same_entry?(stat, File.lstat(path)) && (!private || private_entry?(stat, 0o700))
    unless valid
      handle.close
      raise Telephony::VoiceCoreClient::Error, 'unsafe_spool'
    end
    @directories << [path, stat]

    path
  end

  def stage_recording!
    keys = storage_keys
    staged = keys.any? do |key|
      path = Storage::RecordingPaths.resolve(key, account_id: @call_session.account_id)
      next false unless path

      File.open(path, File::RDONLY | File::NOFOLLOW) { |input| write_audio(key) { |output| copy_local(input, output) } }
      true
    end
    stage_remote!(keys) unless staged
  end

  def stage_remote!(keys)
    raise Telephony::VoiceCoreClient::Error.new('recording_not_found', retryable: true) unless Storage::VoiceRecordingRemoteStorage.enabled?

    service = Storage::VoiceRecordingRemoteStorage.active_storage_service
    candidates = keys.filter_map do |candidate|
      value = Storage::RecordingMetadata.local_key(candidate, account_id: @call_session.account_id)
      value if value&.start_with?('voice-recordings/')
    end
    key = candidates.find { |candidate| service.exist?(candidate) }
    raise Telephony::VoiceCoreClient::Error.new('recording_not_found', retryable: true) unless key

    write_audio(key) do |output|
      bytes = 0
      service.download(key) do |chunk|
        bytes += chunk.bytesize
        check_size!(bytes)
        output.write(chunk)
      end
    end
  end

  def write_audio(key)
    extension = File.extname(key).downcase
    raise Telephony::VoiceCoreClient::Error, 'unsupported_audio' unless EXTENSIONS.include?(extension)

    @audio_filename = "audio#{extension}"
    @audio_path = @directory.join(audio_filename)
    assert_boundaries!
    @audio_file = File.open(@audio_path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600)
    @audio_stat = @audio_file.stat
    raise Telephony::VoiceCoreClient::Error, 'unsafe_spool' unless @audio_stat.file? && private_entry?(@audio_stat, 0o600)

    assert_boundaries!
    @audio_file.binmode
    yield @audio_file
    @audio_file.flush
    raise Telephony::VoiceCoreClient::Error, 'empty_audio' unless @audio_file.pos.positive?
  end

  def copy_local(input, output)
    stat = input.stat
    raise Telephony::VoiceCoreClient::Error, 'invalid_recording' unless stat.file?

    check_size!(stat.size)
    bytes = 0
    while (chunk = input.read(64.kilobytes))
      bytes += chunk.bytesize
      check_size!(bytes)
      output.write(chunk)
    end
  end

  def check_size!(bytes)
    raise Telephony::VoiceCoreClient::Error, 'audio_too_large' if bytes > MAX_AUDIO_BYTES

    assert_boundaries!
  end

  def private_entry?(stat, mode)
    stat.uid == Process.uid && (stat.mode & 0o7777) == mode
  end

  def same_entry?(left, right)
    [left.dev, left.ino, left.uid, left.mode] == [right.dev, right.ino, right.uid, right.mode]
  end

  def assert_boundaries!
    unchanged = @directories.all? { |path, stat| same_entry?(stat, File.lstat(path)) }
    unchanged &&= same_entry?(@audio_stat, File.lstat(@audio_path)) && same_entry?(@audio_stat, @audio_file.stat) if @audio_stat
    raise Telephony::VoiceCoreClient::Error, 'unsafe_spool' unless unchanged
  rescue SystemCallError
    raise Telephony::VoiceCoreClient::Error, 'unsafe_spool'
  end

  def cleanup
    return unless @directory

    assert_boundaries!
    if @audio_stat
      File.unlink(@audio_path)
      @audio_stat = nil
    end
    assert_boundaries!
    Dir.rmdir(@directory)
  rescue Telephony::VoiceCoreClient::Error, SystemCallError
    Rails.logger.warn('[VoiceCore] Private spool identity changed; cleanup skipped')
  ensure
    close_handles
  end

  def close_handles
    [@audio_file, *@directory_handles.reverse].compact.each do |handle|
      handle.close unless handle.closed?
    rescue IOError, SystemCallError
      Rails.logger.warn('[VoiceCore] Private spool descriptor close failed')
    end
  end
end
