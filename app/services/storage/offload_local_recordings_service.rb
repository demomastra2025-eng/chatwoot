# frozen_string_literal: true

# Drains local voice-recordings/* files from server disk into S3 (ps.kz Almaty) while
# keeping database byte_size metadata intact for clinic storage quota accounting.
class Storage::OffloadLocalRecordingsService
  EXTENSION_CONTENT_TYPES = {
    '.mp3' => 'audio/mpeg',
    '.ogg' => 'audio/ogg',
    '.webm' => 'audio/webm',
    '.m4a' => 'audio/mp4',
    '.aac' => 'audio/aac'
  }.freeze

  def initialize(account: nil, dry_run: false)
    @account = account
    @dry_run = ActiveModel::Type::Boolean.new.cast(dry_run)
  end

  def perform
    return { skipped: true, reason: :remote_storage_disabled } unless @dry_run || Storage::VoiceRecordingRemoteStorage.enabled?

    stats = { scanned: 0, compressed: 0, offloaded: 0, freed_bytes: 0, failed: 0 }
    touched_account_ids = Set.new

    sessions_scope.find_each do |session|
      stats[:scanned] += 1
      process_session!(session, stats, touched_account_ids)
    end

    refresh_accounts!(touched_account_ids) unless @dry_run
    stats
  end

  private

  def sessions_scope
    scope = Telephony::CallSession.where.not(recording_ref: [nil, ''])
    @account ? scope.where(account_id: @account.id) : scope
  end

  def process_session!(session, stats, touched_account_ids)
    path = resolve_existing_file(session)
    return unless path

    file_bytes = File.size(path)
    return record_dry_run!(stats, file_bytes) if @dry_run

    path, _file_bytes, finished = compress_if_needed!(session, path, file_bytes, stats, touched_account_ids)
    return if finished

    offload_compressed_session!(session, path, stats, touched_account_ids)
  rescue StandardError => e
    stats[:failed] += 1
    Rails.logger.warn("[Storage::OffloadLocalRecordingsService] session=#{session.id} error=#{e.class}: #{e.message}")
  end

  def resolve_existing_file(session)
    path = Storage::RecordingPaths.resolve(session.recording_ref, account_id: session.account_id)
    path if path && File.file?(path)
  end

  def record_dry_run!(stats, file_bytes)
    stats[:offloaded] += 1
    stats[:freed_bytes] += file_bytes
  end

  def compress_if_needed!(session, path, file_bytes, stats, touched_account_ids)
    return [path, file_bytes, false] unless Telephony::RecordingCompressionService::SUPPORTED_EXTENSIONS.include?(path.extname.downcase)

    res = Telephony::RecordingCompressionService.compress(call_session: session)
    unless res[:success]
      stats[:failed] += 1
      return [path, file_bytes, true]
    end

    stats[:compressed] += 1
    after_compression_state(session, file_bytes, stats, touched_account_ids)
  end

  def after_compression_state(session, original_bytes, stats, touched_account_ids)
    session.reload
    after_path = resolve_existing_file(session)
    if after_path.nil?
      record_offloaded!(stats, touched_account_ids, session.account_id, original_bytes)
      return [nil, 0, true]
    end

    [after_path, File.size(after_path), false]
  end

  def offload_compressed_session!(session, path, stats, touched_account_ids)
    storage_key = Storage::RecordingMetadata.local_key(session.recording_ref, account_id: session.account_id) ||
                  Storage::RecordingMetadata.local_key(path.to_s, account_id: session.account_id)
    return if storage_key.blank? || Storage::VoiceRecordingRemoteStorage.raw_wav_key?(storage_key)

    Storage::RecordingLock.synchronize(account_id: session.account_id, storage_keys: [storage_key]) do
      offload_locked_session!(session, storage_key, path, stats, touched_account_ids)
    end
  end

  def offload_locked_session!(session, storage_key, expected_path, stats, touched_account_ids)
    session.with_lock do
      session.reload
      resolved = resolve_existing_file(session)
      return unless resolved && resolved.to_s == expected_path.to_s

      file_bytes = File.size(resolved)
      content_type = resolve_content_type(session, resolved)
      return unless Storage::VoiceRecordingRemoteStorage.offload_file!(storage_key, resolved, content_type: content_type)

      persist_offloaded_metadata!(session, storage_key, content_type, file_bytes)
      record_offloaded!(stats, touched_account_ids, session.account_id, file_bytes)
    end
  end

  def resolve_content_type(session, resolved)
    session.metadata.to_h.dig('recording', 'content_type').presence ||
      EXTENSION_CONTENT_TYPES.fetch(resolved.extname.downcase, 'audio/mpeg')
  end

  def persist_offloaded_metadata!(session, storage_key, content_type, file_bytes)
    meta = session.metadata.to_h.deep_dup
    recording = meta['recording'].is_a?(Hash) ? meta['recording'].deep_dup : {}
    recording['storage_key'] = storage_key
    recording['byte_size'] = Storage::RecordingMetadata.size(recording['byte_size']) || file_bytes
    recording['content_type'] ||= content_type
    recording['storage_provider'] = 's3'
    recording['remote_stored_at'] = Time.current.iso8601
    meta['recording'] = recording
    session.update!(recording_ref: storage_key, metadata: meta)
  end

  def record_offloaded!(stats, touched_account_ids, account_id, file_bytes)
    stats[:offloaded] += 1
    stats[:freed_bytes] += file_bytes
    touched_account_ids << account_id
  end

  def refresh_accounts!(account_ids)
    Account.where(id: account_ids.to_a).find_each do |account|
      Accounts::StorageOverviewService.new(account: account).invalidate!
    end
  end
end
