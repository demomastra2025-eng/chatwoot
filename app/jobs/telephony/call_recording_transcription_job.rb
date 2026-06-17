class Telephony::CallRecordingTranscriptionJob < ApplicationJob
  queue_as :audio_transcription

  retry_on Telephony::CallRecordingTranscriptionService::RecordingNotFound, wait: 10.seconds, attempts: 3 do |job, error|
    call_session = Telephony::CallSession.find_by(id: job.arguments.first)
    Telephony::CallRecordingTranscriptionJob.mark_transcription_skipped!(call_session, error.message) if call_session.present?

    Rails.logger.warn(
      'Skipping call recording transcription job because the recording file is unavailable: ' \
      "call_session_id=#{job.arguments.first} job_id=#{job.job_id} error_class=#{error.class.name}"
    )
  end

  discard_on RubyLLM::BadRequestError do |job, error|
    Rails.logger.warn(
      'Discarding call recording transcription job due to LLM bad request: ' \
      "call_session_id=#{job.arguments.first} job_id=#{job.job_id} error_class=#{error.class.name}"
    )
  end

  discard_on Faraday::BadRequestError do |job, error|
    Rails.logger.warn(
      'Discarding call recording transcription job due to bad request: ' \
      "call_session_id=#{job.arguments.first} job_id=#{job.job_id} status_code=#{error.response&.dig(:status)}"
    )
  end

  def perform(call_session_id)
    call_session = Telephony::CallSession.find_by(id: call_session_id)
    return if call_session.blank?

    Telephony::CallRecordingTranscriptionService.new(call_session).perform
  end

  def self.mark_transcription_skipped!(call_session, reason)
    call_session.with_lock do
      metadata = (call_session.reload.metadata || {}).deep_dup
      recording = metadata['recording'] ||= {}
      transcription = recording['transcription'] ||= {}
      next if transcription['status'] == 'completed'

      transcription['status'] = 'skipped'
      transcription['reason'] = reason
      transcription['skipped_at'] = Time.current.iso8601
      call_session.update!(metadata: metadata)
    end
  end
end
