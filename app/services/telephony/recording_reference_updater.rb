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
      # Playback serves the file with this type; leaving "audio/wav" here would label an MP3 as WAV.
      'content_type' => CONTENT_TYPE
    )
    recording['duration_seconds'] = duration.round if duration.positive?
    recording['retained_original'] = {
      'storage_key' => old_key,
      'byte_size' => original_byte_size,
      'expires_at' => ORIGINAL_RETENTION_DAYS.days.from_now.iso8601
    }
    meta.merge('recording' => recording)
  end

  # Only the messages of this conversation that actually mention the recording are rewritten, and the
  # rewrite skips model callbacks: re-pointing old calls must not fire message.updated webhooks and
  # automations for every historical message.
  def update_messages!
    return if session.conversation_id.blank?

    playback_url = playback_path
    messages_referencing_recording.find_each do |candidate|
      candidate.with_lock do
        message = Message.find_by(id: candidate.id, account_id: session.account_id, conversation_id: session.conversation_id)
        next unless message

        attributes = message.content_attributes.is_a?(Hash) ? message.content_attributes.deep_dup : {}
        data = attributes['data']
        next unless data.is_a?(Hash) && rewrite_recording_data!(data)

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
      reference, [path], account_id: session.account_id,
      aliases: old_reference_aliases, qualified_references: qualified_references, conservative: false
    )
  end

  def rewrite_recording_data!(data)
    changed = false
    recording = data['recording']
    qualified_references = [
      recording.is_a?(Hash) ? recording['storage_key'] : nil,
      recording.is_a?(Hash) ? recording['recording_ref'] : nil,
      data['storage_key'],
      data['recording_ref']
    ].compact_blank
    recording_storage_matches = recording.is_a?(Hash) && recording_reference_matches?(
      recording['storage_key'], qualified_references: qualified_references
    )
    top_storage_matches = recording_reference_matches?(
      data['storage_key'], qualified_references: qualified_references
    )

    if recording.is_a?(Hash) && recording_storage_matches
      recording['storage_key'] = new_key
      recording['byte_size'] = byte_size
      recording['content_type'] = CONTENT_TYPE if recording.key?('content_type')
      changed = true
    end

    if recording.is_a?(Hash) && recording_reference_matches?(
      recording['recording_ref'], qualified_references: qualified_references
    )
      recording['recording_ref'] = new_key
      changed = true
    end

    if top_storage_matches
      data['storage_key'] = new_key
      changed = true
    end

    if recording_reference_matches?(data['recording_ref'], qualified_references: qualified_references)
      data['recording_ref'] = new_key
      changed = true
    end

    changed
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
    conversations.find_each do |candidate|
      candidate.with_lock do
        conversation = Conversation.find_by(id: candidate.id, account_id: session.account_id)
        next unless conversation

        conversation.reload
        attributes = conversation.additional_attributes
        next unless attributes.is_a?(Hash)

        updated = attributes.deep_dup
        recording = updated['recording']
        changed = false
        qualified_references = [
          recording.is_a?(Hash) ? recording['storage_key'] : nil,
          recording.is_a?(Hash) ? recording['recording_ref'] : nil,
          updated['storage_key'],
          updated['recording_ref']
        ].compact_blank
        if recording.is_a?(Hash)
          if recording_reference_matches?(recording['storage_key'], qualified_references: qualified_references)
            recording['storage_key'] = new_key
            changed = true
          end
          if recording_reference_matches?(recording['recording_ref'], qualified_references: qualified_references)
            recording['recording_ref'] = new_key
            changed = true
          end
        end
        if recording_reference_matches?(updated['storage_key'], qualified_references: qualified_references)
          updated['storage_key'] = new_key
          changed = true
        end
        if recording_reference_matches?(updated['recording_ref'], qualified_references: qualified_references)
          updated['recording_ref'] = new_key
          changed = true
        end
        next unless changed

        updated['recording'] = recording if recording.is_a?(Hash)
        conversation.update!(additional_attributes: updated)
      end
    end
  end
end
