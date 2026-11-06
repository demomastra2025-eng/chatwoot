# frozen_string_literal: true

# Owns only a private, short-lived copy, never the original recording or another tenant's file.
# Keep descriptor lifetime, boundary checks and guarded cleanup in the same ownership scope.
class Telephony::VoiceCoreAudioSpool
  MAX_AUDIO_BYTES = 100.megabytes
  EXTENSIONS = %w[.wav .mp3 .ogg .m4a .flac .aac .webm].freeze

  attr_reader :job_id, :audio_filename

  def initialize(account_id:, source:)
    raise Telephony::VoiceCoreClient::Error, 'invalid_account' unless account_id.is_a?(Integer) && account_id.positive?

    @account_id = account_id
    @source = source
    @job_id = SecureRandom.hex(16)
    @directories = []
    @directory_handles = []
  end

  def open
    prepare_directory!
    @source.stage(self)
    assert_boundaries!
    result = yield self
    assert_boundaries!
    result
  rescue Telephony::VoiceCoreClient::Error, ActiveStorage::FileNotFoundError
    raise
  rescue StandardError
    raise Telephony::VoiceCoreClient::Error, 'staging_failed'
  ensure
    cleanup
  end

  private

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
      safe_directory(current, private: current == root, parent: @directory_handles.last)
    end
    @root_handle = @directory_handles.last

    root
  end

  def prepare_directory!
    root = spool_root!
    account_root = safe_directory(root.join(@account_id.to_s), private: true, parent: @root_handle)
    @account_handle = @directory_handles.last
    candidate = account_root.join(job_id)
    assert_boundaries!
    Dir.mkdir(fd_child(@account_handle, job_id), 0o700)
    safe_directory(candidate, private: true, parent: @account_handle)
    @job_handle = @directory_handles.last
    @directory = candidate
  end

  def safe_directory(path, private: false, parent: nil)
    assert_boundaries!
    anchored = parent ? fd_child(parent, path.basename.to_s) : path
    begin
      Dir.mkdir(anchored, 0o700)
    rescue Errno::EEXIST
      # Existing entries are validated, never chmod/chowned into the trust boundary.
    end
    handle = File.open(anchored, File::RDONLY | File::NOFOLLOW | File::NONBLOCK)
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

  def fd_child(parent, name)
    valid = name.is_a?(String) && name.present? && %w[. ..].exclude?(name) && name.exclude?('/') && name.exclude?("\0")
    raise Telephony::VoiceCoreClient::Error, 'unsafe_spool' unless valid

    Pathname.new("/proc/self/fd/#{parent.fileno}/#{name}")
  end

  def write_audio(extension)
    prepare_audio!(extension)
    yield chunk_writer
    @audio_file.flush
    raise Telephony::VoiceCoreClient::Error, 'empty_audio' unless @audio_file.pos.positive?
  end
  public :write_audio

  def prepare_audio!(extension)
    raise Telephony::VoiceCoreClient::Error, 'unsupported_audio' unless EXTENSIONS.include?(extension)
    raise Telephony::VoiceCoreClient::Error, 'unsafe_spool' if @audio_file

    @audio_filename = "audio#{extension}"
    @audio_path = @directory.join(audio_filename)
    assert_boundaries!
    @audio_file = File.open(fd_child(@job_handle, audio_filename), File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600)
    @audio_stat = @audio_file.stat
    raise Telephony::VoiceCoreClient::Error, 'unsafe_spool' unless @audio_stat.file? && private_entry?(@audio_stat, 0o600)

    assert_boundaries!
    @audio_file.binmode
  end

  def chunk_writer
    bytes = 0
    lambda do |chunk|
      raise Telephony::VoiceCoreClient::Error, 'invalid_audio_chunk' unless chunk.is_a?(String)

      bytes += chunk.bytesize
      check_size!(bytes)
      @audio_file.write(chunk)
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
      File.unlink(fd_child(@job_handle, audio_filename))
      @audio_stat = nil
    end
    assert_boundaries!
    Dir.rmdir(fd_child(@account_handle, job_id))
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
