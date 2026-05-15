class Telephony::CallRecordingTranscriptionJob < ApplicationJob
  queue_as :audio_transcription

  retry_on Telephony::CallRecordingTranscriptionService::RecordingNotFound, wait: 10.seconds, attempts: 3

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
end
