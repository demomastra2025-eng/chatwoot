class Telephony::RecordingImportJob < ApplicationJob
  queue_as :default

  retry_on Telephony::RecordingImportService::RetryableError, wait: 30.seconds, attempts: 5
  discard_on Telephony::RecordingImportService::NonRetryableError do |_job, error|
    Rails.logger.warn("TELEPHONY_RECORDING_IMPORT_DISCARDED error=#{error.class.name} message=#{error.message}")
  end

  def perform(payload)
    Telephony::RecordingImportService.new(payload: payload).perform
  end
end
