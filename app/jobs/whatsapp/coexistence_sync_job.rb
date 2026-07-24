class Whatsapp::CoexistenceSyncJob < ApplicationJob
  queue_as :whatsappweb_history

  retry_on Whatsapp::FacebookApiClient::Error, wait: :polynomially_longer, attempts: 5 do |job, error|
    channel = Channel::Whatsapp.find_by(id: job.arguments.first)
    generation = job.arguments.second
    if channel.present? && generation.present?
      Whatsapp::CoexistenceSyncReconciliationService.new(channel).require_manual_recovery!(error, generation: generation)
    end
  end
  retry_on Whatsapp::WabaLock::LockAcquisitionError, wait: 1.second, attempts: 8
  discard_on ActiveRecord::RecordNotFound
  discard_on Whatsapp::CoexistenceSyncService::RequestOutcomeUnknownError do |job, error|
    Rails.logger.error(
      "[WHATSAPP] Coexistence sync request outcome is unknown for channel #{job.arguments.first}: #{error.message}"
    )
    Whatsapp::CoexistenceSyncReconciliationJob.set(wait: 15.minutes).perform_later(job.arguments.first, job.arguments.second)
  end

  def perform(channel_id, generation)
    channel = Channel::Whatsapp.find(channel_id)
    return unless channel.account&.active? && channel.inbox.present? && channel.inbox.deleting_at.nil?
    return unless generation.present? && channel.provider_config.dig('coexistence_sync', 'generation').to_s == generation.to_s

    Whatsapp::CoexistenceSyncService.new(channel, generation: generation).perform
  end
end
