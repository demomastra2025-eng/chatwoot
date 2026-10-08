# frozen_string_literal: true

# Moves the original WAV that is kept after compression into the account trash once its retention ends. The
# trash keeps it for another 30 days and an administrator can restore it; nothing is deleted here.
# The job is off until TELEPHONY_PURGE_RETAINED_RECORDINGS_ENABLED=true is set explicitly.
class Telephony::PurgeRetainedRecordingsJob < ApplicationJob
  ENABLED_ENV = 'TELEPHONY_PURGE_RETAINED_RECORDINGS_ENABLED'

  queue_as :housekeeping

  def self.enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch(ENABLED_ENV, false)) == true
  end

  def perform(now = Time.current)
    return { disabled: true } unless self.class.enabled?

    now = Time.zone.parse(now) if now.is_a?(String)
    # Originals already in the trash, restored or purged are not picked up again.
    scope = Telephony::CallSession.where("metadata #>> '{recording,retained_original,expires_at}' <= ?", now.iso8601)
                                  .where("metadata #> '{recording,retained_original,trash}' IS NULL")
                                  .where("metadata #>> '{recording,retained_original,purged_at}' IS NULL")
    stats = { trashed: 0, skipped: 0, failed: 0 }

    scope.find_each do |session|
      result = trash_expired_original(session, now)
      stats[result] += 1
    rescue StandardError => e
      stats[:failed] += 1
      Rails.logger.warn("[PurgeRetainedRecordingsJob] Failed for call session #{session.id}: #{e.class.name}")
    end
    Rails.logger.info("[PurgeRetainedRecordingsJob] Retained audio moved to trash: #{stats.inspect}")
    stats
  end

  private

  # Keep expiry, live-reference, path-ownership and metadata publication checks in one locked critical section.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def trash_expired_original(session, now)
    expected_key = session.metadata.to_h.dig('recording', 'retained_original', 'storage_key').to_s
    return :skipped if expected_key.blank?

    result = :skipped
    moved = nil
    Storage::RecordingLock.synchronize(account_id: session.account_id, storage_keys: [expected_key]) do
      session.with_lock do
        session.reload
        metadata = (session.metadata || {}).deep_dup
        recording = metadata['recording'].is_a?(Hash) ? metadata['recording'] : {}
        retained = recording['retained_original'].is_a?(Hash) ? recording['retained_original'].deep_dup : nil
        expires_at = Time.zone.parse(retained['expires_at'].to_s) if retained
        next unless retained && expires_at && expires_at <= now

        key = retained['storage_key'].to_s
        next if key.blank? || key != expected_key

        path = Storage::RecordingPaths.resolve(key, account_id: session.account_id)
        next unless path
        next unless compressed_recording_present?(session)
        next if Storage::RecordingPaths.same_physical_file?(key, session.recording_ref, account_id: session.account_id)
        next if retained_original_referenced?(session, key, path)

        trash_service = Storage::TrashService.new(account: session.account)
        moved = { service: trash_service, original_path: path.to_s, trash_path: trash_service.retained_original_trash_path(session, path) }
        trash_service.trash_retained_original!(session, path)
        result = :trashed
      end
    end
    refresh_storage_breakdown(session) if result == :trashed
    result
  rescue ActiveRecord::RecordNotFound
    :skipped
  rescue StandardError
    # The file moved before the transaction that publishes its trash manifest ended: when that transaction did not
    # commit, put the original back so it is not orphaned in the trash without a way to restore it.
    if moved && session.reload.metadata.to_h.dig('recording', 'retained_original', 'trash').blank?
      moved[:service].undo_retained_original_move(moved[:original_path], moved[:trash_path])
    end
    raise
  end

  # Request the cached overview after the commit so a failed request cannot roll the trash manifest back.
  def refresh_storage_breakdown(session)
    Accounts::StorageOverviewService.new(account: session.account).schedule_refresh(force: true)
  rescue StandardError => e
    Rails.logger.warn("[PurgeRetainedRecordingsJob] Storage refresh request failed account=#{session.account_id}: #{e.class.name}")
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  # The original is the only other copy: it is never moved while the current recording is missing or empty.
  def compressed_recording_present?(session)
    current = Storage::RecordingPaths.resolve(session.recording_ref, account_id: session.account_id)
    current.present? && File.file?(current) && File.size(current).positive?
  end

  def retained_original_referenced?(session, key, path)
    aliases = Storage::RecordingPaths.reference_aliases(path, account_id: session.account_id).presence || [key]
    account_sessions = Telephony::CallSession.where(account_id: session.account_id).where.not(id: session.id)
    session_sql = <<~SQL.squish
      recording_ref IN (:refs) OR
      metadata #>> '{recording,storage_key}' IN (:refs) OR
      metadata #>> '{recording,recording_ref}' IN (:refs) OR
      metadata #>> '{recording,retained_original,storage_key}' IN (:refs) OR
      metadata #>> '{trash,original_recording_ref}' IN (:refs) OR
      metadata #>> '{trash,original_path}' IN (:refs) OR
      metadata #>> '{trash,trash_path}' IN (:refs) OR
      EXISTS (
        SELECT 1
        FROM jsonb_array_elements(
          CASE WHEN jsonb_typeof(metadata #> '{trash,files}') = 'array'
               THEN metadata #> '{trash,files}' ELSE '[]'::jsonb END
        ) AS manifest_file(value)
        WHERE manifest_file.value->>'storage_key' IN (:refs)
          OR manifest_file.value->>'original_path' IN (:refs)
          OR manifest_file.value->>'trash_path' IN (:refs)
      )
    SQL
    if account_sessions.where(session_sql, refs: aliases).find_each.any? do |candidate|
         values = recording_values(candidate)
         values.any? do |reference|
           reference_points_to_path?(reference, aliases, path, session.account_id, qualified_references: values)
         end
       end
      return true
    end

    messages = Message.where(account_id: session.account_id).with_recording_reference_candidates(aliases)
    return true if messages.find_each.any? do |message|
      data = message.content_attributes.to_h['data']
      recording = data.is_a?(Hash) ? data['recording'] : nil
      values = [
        data.is_a?(Hash) ? data['storage_key'] : nil,
        data.is_a?(Hash) ? data['recording_ref'] : nil,
        recording.is_a?(Hash) ? recording['storage_key'] : nil,
        recording.is_a?(Hash) ? recording['recording_ref'] : nil,
        recording.is_a?(Hash) ? recording.dig('retained_original', 'storage_key') : nil
      ]
      qualified_references = [
        data.is_a?(Hash) ? data['storage_key'] : nil,
        data.is_a?(Hash) ? data['recording_ref'] : nil,
        recording.is_a?(Hash) ? recording['storage_key'] : nil,
        recording.is_a?(Hash) ? recording['recording_ref'] : nil
      ].compact_blank
      values.any? do |reference|
        reference_points_to_path?(
          reference, aliases, path, session.account_id, qualified_references: qualified_references
        )
      end
    end

    conversation_sql = <<~SQL.squish
      additional_attributes #>> '{storage_key}' IN (:refs) OR
      additional_attributes #>> '{recording,storage_key}' IN (:refs) OR
      additional_attributes #>> '{recording,recording_ref}' IN (:refs) OR
      additional_attributes #>> '{recording,retained_original,storage_key}' IN (:refs) OR
      additional_attributes #>> '{recording_ref}' IN (:refs)
    SQL
    conversations = Conversation.where(account_id: session.account_id).where(conversation_sql, refs: aliases)
    conversations.find_each.any? do |conversation|
      attributes = conversation.additional_attributes
      recording = attributes.is_a?(Hash) ? attributes['recording'] : nil
      values = [
        recording.is_a?(Hash) ? recording['storage_key'] : nil,
        recording.is_a?(Hash) ? recording['recording_ref'] : nil,
        recording.is_a?(Hash) ? recording.dig('retained_original', 'storage_key') : nil,
        attributes.is_a?(Hash) ? attributes['storage_key'] : nil,
        attributes.is_a?(Hash) ? attributes['recording_ref'] : nil
      ]
      qualified_references = [
        recording.is_a?(Hash) ? recording['storage_key'] : nil,
        recording.is_a?(Hash) ? recording['recording_ref'] : nil,
        attributes.is_a?(Hash) ? attributes['storage_key'] : nil,
        attributes.is_a?(Hash) ? attributes['recording_ref'] : nil
      ].compact_blank
      values.any? do |reference|
        reference_points_to_path?(
          reference, aliases, path, session.account_id, qualified_references: qualified_references
        )
      end
    end
  end

  def recording_values(session)
    metadata = session.metadata.to_h
    trash = metadata['trash'].is_a?(Hash) ? metadata['trash'] : {}
    manifest_values = Array(trash['files']).flat_map do |entry|
      %w[storage_key original_path trash_path].map { |key| entry[key] }
    end
    [
      session.recording_ref,
      metadata.dig('recording', 'storage_key'),
      metadata.dig('recording', 'recording_ref'),
      metadata.dig('recording', 'retained_original', 'storage_key'),
      trash['original_recording_ref'],
      trash['original_path'],
      trash['trash_path'],
      *manifest_values
    ].compact_blank
  end

  def reference_points_to_path?(reference, aliases, path, account_id, qualified_references: [])
    Storage::RecordingPaths.reference_matches_paths?(
      reference, [path], account_id: account_id, aliases: aliases,
      qualified_references: qualified_references
    )
  end
end
