# frozen_string_literal: true

class Telephony::CompressRecordingsJob < ApplicationJob
  queue_as :scheduled_jobs

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity
  def perform(account_id: nil, call_session_id: nil, batch_size: 50)
    if call_session_id.present?
      target_session = Telephony::CallSession.find_by(id: call_session_id)
      return unless target_session

      Telephony::RecordingCompressionService.compress(call_session: target_session)
      return
    end

    scope = Telephony::CallSession.where.not(recording_ref: [nil, ''])
                                  .where('recording_ref ILIKE ? OR recording_ref ILIKE ?', '%.wav', '%.wave')
    scope = scope.where(account_id: account_id) if account_id.present?

    sessions = scope.order(created_at: :asc).limit(batch_size)
    processed_count = 0

    sessions.find_each do |sess|
      result = Telephony::RecordingCompressionService.compress(call_session: sess)
      processed_count += 1 if result[:success]
    rescue StandardError => e
      Rails.logger.warn("[CompressRecordingsJob] Failed session #{sess.id}: #{e.message}")
    end

    # If there are more pending uncompressed recordings, enqueue next batch
    if sessions.count == batch_size && scope.exists?(['id > ?', sessions.last.id])
      self.class.set(wait: 10.seconds).perform_later(account_id: account_id, batch_size: batch_size)
    end

    Rails.logger.info("[CompressRecordingsJob] Processed #{processed_count} recordings")
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity
end
