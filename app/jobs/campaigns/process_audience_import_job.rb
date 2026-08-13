class Campaigns::ProcessAudienceImportJob < ApplicationJob
  queue_as :housekeeping
  retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
    audience_import = job.arguments.first
    Rails.logger.error("[CAMPAIGN AUDIENCE IMPORT] import=#{audience_import.id} exhausted retries: #{error.class}")
    job.class.transition_to_failed(audience_import, error_code: 'processing_failed')
    job.class.enqueue_source_purge(audience_import)
  end
  retry_on ActiveStorage::FileNotFoundError, wait: :polynomially_longer, attempts: 3 do |job, error|
    audience_import = job.arguments.first
    Rails.logger.error("[CAMPAIGN AUDIENCE IMPORT] import=#{audience_import.id} exhausted retries: #{error.class}")
    job.class.transition_to_failed(audience_import, error_code: 'processing_failed')
    job.class.enqueue_source_purge(audience_import)
  end

  def perform(audience_import)
    audience_import.with_lock do
      next unless processable?(audience_import)

      Campaigns::AudienceImportService.new(audience_import: audience_import).perform
    end
  rescue ActiveStorage::FileNotFoundError
    raise
  rescue Campaigns::AudienceImportService::Error => e
    self.class.transition_to_failed(audience_import, error_code: e.code)
  rescue StandardError => e
    Rails.logger.error("[CAMPAIGN AUDIENCE IMPORT] import=#{audience_import.id} failed: #{e.class}")
    raise
  ensure
    self.class.enqueue_source_purge(audience_import)
  end

  def self.enqueue_source_purge(audience_import)
    audience_import.reload
    return unless audience_import.import_file.attached? && (audience_import.completed? || audience_import.failed?)

    Campaigns::PurgeAudienceImportSourceJob.perform_later(audience_import.id)
  rescue ActiveRecord::RecordNotFound
    nil
  rescue StandardError => e
    Rails.logger.error("[CAMPAIGN AUDIENCE IMPORT] import=#{audience_import.id} source purge enqueue failed: #{e.class}")
    false
  end

  def self.transition_to_failed(audience_import, error_code:)
    transitioned = false
    audience_import.with_lock do
      audience_import.reload
      next unless audience_import.pending? || audience_import.processing?

      audience_import.update!(status: :failed, processing_error: error_code)
      transitioned = true
    end
    transitioned
  rescue ActiveRecord::RecordNotFound
    false
  end

  private

  def processable?(audience_import)
    !audience_import.completed? && !audience_import.failed? && audience_import.claimed_at.blank?
  end
end
