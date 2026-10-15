# frozen_string_literal: true

# Points every place that knows about a call recording (the call session, the messages of its
# conversation and the conversation itself) from the old storage key to the new one. Runs in a single
# transaction and raises on failure, so callers can keep the old file when anything goes wrong.
class Telephony::RecordingReferenceUpdater
  CONTENT_TYPE = 'audio/mpeg'
  CODEC = 'mp3_64k'

  ORIGINAL_RETENTION_DAYS = 30

  def initialize(session:, old_key:, compressed:)
    @session = session
    @old_key = old_key
    @new_key = compressed.storage_key
    @byte_size = compressed.byte_size
    @original_byte_size = compressed.original_byte_size
    @duration = compressed.duration
  end

  def perform!
    ActiveRecord::Base.transaction do
      session.with_lock do
        session.reload
        raise ActiveRecord::RecordNotSaved, 'Recording reference changed before compression completed' unless session.recording_ref == old_key

        update_call_session!
        update_messages!
        update_conversation!
      end
    end
    session
  end

  private

  attr_reader :session, :old_key, :new_key, :byte_size, :original_byte_size, :duration

  def update_call_session!
    session.recording_ref = new_key
    session.metadata = metadata_with_compressed_recording
    session.duration_seconds ||= duration.round if duration.positive?
    session.save!
  end

  def metadata_with_compressed_recording
    meta = session.metadata.is_a?(Hash) ? session.metadata.deep_dup : {}
    recording = meta['recording'].is_a?(Hash) ? meta['recording'] : {}
    recording.merge!(
      'storage_key' => new_key,
      'byte_size' => byte_size,
      'compressed' => true,
      'codec' => CODEC,
      'content_type' => CONTENT_TYPE
    )
    recording['duration_seconds'] = duration.round if duration.positive?
    now_iso = Time.current.iso8601
    recording['retained_original'] = {
      'storage_key' => old_key, 'byte_size' => original_byte_size,
      'expires_at' => now_iso, 'purged_at' => now_iso
    }
    meta.merge('recording' => recording)
  end

  def update_messages!
    return if session.conversation_id.blank?

    playback_url = playback_path
    messages_referencing_recording.find_each do |candidate|
      candidate.with_lock do
        message = Message.find_by(id: candidate.id, account_id: session.account_id, conversation_id: session.conversation_id)
        next unless message

        attributes = message.content_attributes.is_a?(Hash) ? message.content_attributes.deep_dup : {}
        data = attributes['data']
        next unless data.is_a?(Hash) && rewrite_recording_data!(data, update_nested_meta: true)

        data['recording_url'] = playback_url if playback_url
        attributes['data'] = data
        message.update_columns(content_attributes: attributes, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      end
    end
  end

  def messages_referencing_recording
    Message.where(account_id: session.account_id, conversation_id: session.conversation_id)
           .with_recording_reference_candidates(old_reference_aliases)
  end

  def old_reference_aliases
    source_path = Storage::RecordingPaths.resolve(old_key, account_id: session.account_id)
    aliases = source_path ? Storage::RecordingPaths.reference_aliases(source_path, account_id: session.account_id) : []
    (aliases + [old_key]).compact_blank.uniq
  end

  def recording_reference_matches?(reference, qualified_references: [])
    return false if reference.blank?

    path = Storage::RecordingPaths.resolve(old_key, account_id: session.account_id)
    return false unless path

    Storage::RecordingPaths.reference_matches_paths?(
      reference, [path],
      account_id: session.account_id,
      aliases: old_reference_aliases,
      qualified_references: qualified_references,
      conservative: false
    )
  end

  def rewrite_recording_data!(container, update_nested_meta: false)
    recording = container['recording']
    refs = extract_qualified_references(container, recording)
    changed = rewrite_nested_recording!(recording, refs, update_nested_meta: update_nested_meta)
    changed = rewrite_key_if_matches!(container, 'storage_key', refs) || changed
    rewrite_key_if_matches!(container, 'recording_ref', refs) || changed
  end

  def extract_qualified_references(container, recording)
    [
      recording.is_a?(Hash) ? recording['storage_key'] : nil,
      recording.is_a?(Hash) ? recording['recording_ref'] : nil,
      container['storage_key'],
      container['recording_ref']
    ].compact_blank
  end

  def rewrite_nested_recording!(recording, refs, update_nested_meta: false)
    return false unless recording.is_a?(Hash)

    changed = false
    if recording_reference_matches?(recording['storage_key'], qualified_references: refs)
      recording['storage_key'] = new_key
      if update_nested_meta
        recording['byte_size'] = byte_size
        recording['content_type'] = CONTENT_TYPE if recording.key?('content_type')
      end
      changed = true
    end
    rewrite_key_if_matches!(recording, 'recording_ref', refs) || changed
  end

  def rewrite_key_if_matches!(hash, key, refs)
    return false unless recording_reference_matches?(hash[key], qualified_references: refs)

    hash[key] = new_key
    true
  end

  def conversation_reference_conditions
    <<~SQL.squish
      additional_attributes #>> '{storage_key}' IN (:refs) OR
      additional_attributes #>> '{recording,storage_key}' IN (:refs) OR
      additional_attributes #>> '{recording,recording_ref}' IN (:refs) OR
      additional_attributes #>> '{recording_ref}' IN (:refs)
    SQL
  end

  def playback_path
    Telephony::CallRecordingPlaybackUrl.path_for(session, storage_key: new_key)
  rescue StandardError
    nil
  end

  def update_conversation!
    return if session.conversation_id.blank?

    conversations = Conversation.where(id: session.conversation_id, account_id: session.account_id)
                                .where(conversation_reference_conditions, refs: old_reference_aliases)
    conversations.find_each { |candidate| update_locked_conversation!(candidate) }
  end

  def update_locked_conversation!(candidate)
    candidate.with_lock do
      conversation = Conversation.find_by(id: candidate.id, account_id: session.account_id)
      return unless conversation

      conversation.reload
      attributes = conversation.additional_attributes
      return unless attributes.is_a?(Hash)

      updated = attributes.deep_dup
      return unless rewrite_recording_data!(updated)

      conversation.update!(additional_attributes: updated)
    end
  end
end
