# frozen_string_literal: true

# A tenant-owned recording source for the shared private VoiceCore audio lifecycle.
class Telephony::VoiceCoreRecordingSpool
  def initialize(call_session)
    @call_session = call_session
  end

  def open(&)
    Telephony::VoiceCoreAudioSpool.new(account_id: @call_session.account_id, source: self).open(&)
  end

  def stage(spool)
    keys = storage_keys
    staged = keys.any? do |key|
      path = Storage::RecordingPaths.resolve(key, account_id: @call_session.account_id)
      next false unless path

      File.open(path, File::RDONLY | File::NOFOLLOW) { |input| copy_local(input, key, spool) }
      true
    end
    stage_remote!(keys, spool) unless staged
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

  def stage_remote!(keys, spool)
    raise Telephony::VoiceCoreClient::Error.new('recording_not_found', retryable: true) unless Storage::VoiceRecordingRemoteStorage.enabled?

    service = Storage::VoiceRecordingRemoteStorage.active_storage_service
    candidates = keys.filter_map do |candidate|
      value = Storage::RecordingMetadata.local_key(candidate, account_id: @call_session.account_id)
      value if value&.start_with?('voice-recordings/')
    end
    key = candidates.find { |candidate| service.exist?(candidate) }
    raise Telephony::VoiceCoreClient::Error.new('recording_not_found', retryable: true) unless key

    spool.write_audio(File.extname(key).downcase) do |write|
      service.download(key) do |chunk|
        write.call(chunk)
      end
    end
  end

  def copy_local(input, key, spool)
    raise Telephony::VoiceCoreClient::Error, 'invalid_recording' unless input.stat.file?

    spool.write_audio(File.extname(key).downcase) do |write|
      while (chunk = input.read(64.kilobytes))
        write.call(chunk)
      end
    end
  end
end
