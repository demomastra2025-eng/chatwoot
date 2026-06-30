# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'safe_fetch'
require 'securerandom'
require 'uri'

class Telephony::ExternalRecordingCacheService
  Result = Data.define(:storage_key, :path, :byte_size, :content_type)

  def self.cache!(call_session:, external_recording_url: nil, result: nil, source: 'external_recording_cache')
    new(
      call_session: call_session,
      external_recording_url: external_recording_url,
      result: result,
      source: source
    ).cache!
  end

  def self.cache(call_session:, external_recording_url: nil, result: nil, source: 'external_recording_cache')
    new(
      call_session: call_session,
      external_recording_url: external_recording_url,
      result: result,
      source: source
    ).cache
  end

  def initialize(call_session:, external_recording_url: nil, result: nil, source: 'external_recording_cache')
    @call_session = call_session
    @external_recording_url = external_recording_url
    @result = result
    @source = source
  end

  def cache
    cache!
  rescue StandardError => e
    log_cache_failure(e)
    nil
  end

  def cache!
    return unless cache_external_recordings?
    return unless Telephony::ExternalRecordingPlaybackPolicy.proxy?(resolved_external_recording_url)

    cached_result = existing_cached_result
    return cached_result if cached_result.present?

    recording_result = result || fetch_external_recording
    storage_key = external_recording_cache_storage_key(recording_result)
    path = write_cached_recording!(recording_result, storage_key)
    update_cached_recording_metadata!(recording_result, storage_key)

    Result.new(
      storage_key: storage_key,
      path: path.to_s,
      byte_size: recording_result.data.bytesize,
      content_type: recording_result.content_type
    )
  end

  private

  attr_reader :call_session, :external_recording_url, :result, :source

  def fetch_external_recording
    Telephony::ExternalRecordingPlaybackProxy.fetch(
      url: resolved_external_recording_url,
      fallback_content_type: recording_content_type,
      fallback_filename: proxy_recording_filename
    )
  end

  def cache_external_recordings?
    ENV.fetch('TELEPHONY_EXTERNAL_RECORDING_CACHE_ENABLED', 'true') != 'false'
  end

  def existing_cached_result
    storage_key = recording_metadata['storage_key'].presence || local_recording_ref
    return if storage_key.blank?
    return unless storage_key.start_with?('voice-recordings/')

    path = cached_recording_path(storage_key)
    return unless path.present? && File.file?(path)

    Result.new(
      storage_key: storage_key,
      path: path.to_s,
      byte_size: File.size(path),
      content_type: recording_content_type
    )
  end

  def local_recording_ref
    recording_ref = call_session.recording_ref.to_s
    recording_ref if recording_ref.start_with?('voice-recordings/')
  end

  def write_cached_recording!(recording_result, storage_key)
    path = cached_recording_path(storage_key)
    raise ArgumentError, "unsafe recording storage key: #{storage_key}" if path.blank?

    FileUtils.mkdir_p(path.dirname)
    tmp_path = path.dirname.join(".#{path.basename}.tmp-#{SecureRandom.hex(8)}")
    File.binwrite(tmp_path, recording_result.data)
    FileUtils.mv(tmp_path, path)
    path
  ensure
    FileUtils.rm_f(tmp_path) if defined?(tmp_path) && tmp_path.present?
  end

  def cached_recording_path(storage_key)
    return if storage_key.blank?
    return unless storage_key.start_with?('voice-recordings/')

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

  def external_recording_cache_storage_key(recording_result)
    digest = Digest::SHA256.hexdigest(resolved_external_recording_url)
    "voice-recordings/#{call_session.provider}/#{call_session.account_id}/#{call_session.id}/#{digest}#{recording_extension(recording_result)}"
  end

  def recording_extension(recording_result)
    content_type = recording_result.content_type.to_s
    return '.mp3' if content_type.include?('mpeg')
    return '.ogg' if content_type.include?('ogg')
    return '.webm' if content_type.include?('webm')
    return '.m4a' if content_type.include?('mp4') || content_type.include?('m4a')

    filename_extension = File.extname(recording_result.filename.to_s)
    return filename_extension if filename_extension.match?(/\A\.[a-z0-9]{2,5}\z/i)

    '.wav'
  end

  def update_cached_recording_metadata!(recording_result, storage_key)
    call_session.with_lock do
      call_session.reload
      metadata = call_session.metadata.to_h.deep_dup
      recording = recording_metadata.deep_dup
      recording['recording_ref'] ||= resolved_external_recording_url
      recording['recording_url'] ||= resolved_external_recording_url
      recording['external_recording_url'] ||= resolved_external_recording_url
      recording['storage_key'] = storage_key
      recording['content_type'] = recording_result.content_type if recording_result.content_type.to_s.start_with?('audio/')
      recording['byte_size'] = recording_result.data.bytesize
      recording['cached_at'] = Time.current.iso8601
      recording['cache_source'] = source
      metadata['recording'] = recording.compact

      call_session.update!(recording_ref: storage_key, metadata: metadata)
    end
  end

  def resolved_external_recording_url
    return @resolved_external_recording_url if defined?(@resolved_external_recording_url)

    @resolved_external_recording_url = parsed_external_recording_url
  end

  def parsed_external_recording_url
    candidate = external_recording_url.presence ||
                recording_metadata['external_recording_url'].presence ||
                recording_metadata['recording_url'].presence ||
                recording_metadata['recording_ref'].presence ||
                call_session.recording_ref.presence
    return if candidate.blank?

    uri = URI.parse(candidate.to_s)
    return unless uri.is_a?(URI::HTTP) && uri.host.present?

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

  def recording_content_type
    content_type = recording_metadata['content_type'].to_s
    return content_type if content_type.start_with?('audio/')

    'audio/wav'
  end

  def proxy_recording_filename
    basename = URI.parse(resolved_external_recording_url).path.split('/').last.presence
    return basename if basename.present? && basename.include?('.')

    "call-recording-#{call_session.id}.wav"
  rescue URI::InvalidURIError
    "call-recording-#{call_session.id}.wav"
  end

  def recording_metadata
    metadata = call_session.metadata
    recording = metadata.is_a?(Hash) ? metadata['recording'] : nil
    recording.is_a?(Hash) ? recording.deep_stringify_keys : {}
  end

  def log_cache_failure(error)
    Rails.logger.warn(
      "TELEPHONY_EXTERNAL_RECORDING_CACHE_FAILED account_id=#{call_session.account_id} " \
      "call_session_id=#{call_session.id} provider=#{call_session.provider} error_class=#{error.class.name} message=#{error.message}"
    )
  end
end
