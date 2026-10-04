# frozen_string_literal: true

class Telephony::CompressRecordingsJob < ApplicationJob
  DEFAULT_BATCH_SIZE = 50
  COMPLETION_RETRY_DELAY = 20.seconds
  COMPLETION_RETRY_ATTEMPTS = 30

  queue_as :housekeeping

  # Walks the uncompressed recordings in id order, `batch_size` at a time. Each batch schedules the next
  # one *after its last id*, so a recording that cannot be compressed (file missing, provider-hosted
  # reference, ffmpeg refusing it) is passed over instead of being selected and retried forever.
  def perform(account_id: nil, call_session_id: nil, batch_size: DEFAULT_BATCH_SIZE, after_id: 0, completion_attempt: 0)
    if call_session_id.present?
      session = Telephony::CallSession.find_by(id: call_session_id)
      return false unless session
      unless session.ended_at.present? || session.terminal?
        if completion_attempt.to_i < COMPLETION_RETRY_ATTEMPTS
          self.class.set(wait: COMPLETION_RETRY_DELAY).perform_later(
            call_session_id: session.id, completion_attempt: completion_attempt.to_i + 1
          )
        end
        return false
      end

      return compress_session(session)
    end

    raise ArgumentError, 'account_id is required for historical compression batches' if account_id.blank?

    batch_size = Integer(batch_size).clamp(1, DEFAULT_BATCH_SIZE)
    sessions = pending_sessions(account_id).where('id > ?', after_id).order(:id).limit(batch_size).to_a
    return if sessions.empty?

    processed_count = sessions.count { |candidate| compress_session(candidate) }
    Rails.logger.info("[CompressRecordingsJob] Processed #{processed_count} of #{sessions.size} recordings (after id #{after_id})")

    return if sessions.size < batch_size

    self.class.set(wait: 10.seconds).perform_later(account_id: account_id, batch_size: batch_size, after_id: sessions.last.id)
  end

  private

  def pending_sessions(account_id)
    scope = Telephony::CallSession.where(account_id: account_id).where.not(recording_ref: [nil, ''])
                                  .where('recording_ref ILIKE ? OR recording_ref ILIKE ? OR recording_ref ILIKE ?', '%.wav', '%.wave', '%.pcm')
    scope
  end

  def compress_session(session)
    return false unless session

    Telephony::RecordingCompressionService.compress(call_session: session)[:success] == true
  rescue StandardError => e
    Rails.logger.warn("[CompressRecordingsJob] Failed session #{session.id}: #{e.class.name}: #{e.message}")
    false
  end
end
