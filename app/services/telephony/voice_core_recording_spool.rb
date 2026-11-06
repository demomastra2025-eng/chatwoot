# frozen_string_literal: true

# Owns only a private, short-lived copy, never the original recording or another tenant's file.
class Telephony::VoiceCoreRecordingSpool
  MAX_AUDIO_BYTES = 100.megabytes
  EXTENSIONS = %w[.wav .mp3 .ogg .m4a .flac].freeze

  attr_reader :job_id, :audio_filename

  def initialize(call_session)
    @call_session = call_session
    @job_id = SecureRandom.hex(16)
  end

  def open
    prepare_directory!
    stage_recording!
    yield self
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

    current = Pathname.new('/')
    root.each_filename { |part| current = safe_directory(current.join(part)) }
    raise Telephony::VoiceCoreClient::Error, 'unsafe_spool' unless File.stat(root).mode.nobits?(0o007)

    root
  end

  def prepare_directory!
    root = spool_root!
    account_root = safe_directory(root.join(@call_session.account_id.to_s))
    candidate = account_root.join(job_id)
    Dir.mkdir(candidate, 0o700)
    @directory = candidate
  end

  def safe_directory(path)
    begin
      Dir.mkdir(path, 0o700)
    rescue Errno::EEXIST
      # Existing deployment-owned parents are allowed, symlinks are not.
    end
    stat = File.lstat(path)
    raise Telephony::VoiceCoreClient::Error, 'unsafe_spool' unless stat.directory? && !stat.symlink?

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
    path = @directory.join(audio_filename)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |output|
      output.binmode
      yield output
      raise Telephony::VoiceCoreClient::Error, 'empty_audio' unless output.pos.positive?
    end
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
  end

  def cleanup
    return unless @directory && File.directory?(@directory) && !File.symlink?(@directory)

    File.unlink(@directory.join(audio_filename)) if audio_filename && File.file?(@directory.join(audio_filename))
    Dir.rmdir(@directory)
  rescue SystemCallError
    Rails.logger.warn('[VoiceCore] Private spool cleanup failed')
  end
end
