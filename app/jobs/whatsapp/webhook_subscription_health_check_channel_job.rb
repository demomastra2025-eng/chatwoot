class Whatsapp::WebhookSubscriptionHealthCheckChannelJob < ApplicationJob
  queue_as :scheduled_jobs

  retry_on Whatsapp::WabaLock::LockAcquisitionError,
           Whatsapp::FacebookApiClient::WebhookRecoveryAnchorRequiredError,
           Whatsapp::WebhookSetupService::CallbackSetupError,
           Whatsapp::WebhookSubscriptionHealthService::CheckError,
           wait: :polynomially_longer,
           attempts: 3
  discard_on ActiveRecord::RecordNotFound
  discard_on Whatsapp::WebhookSetupService::StaleRecoveryIdentityError

  def perform(channel_id)
    channel = Channel::Whatsapp.find(channel_id)
    return unless eligible_channel?(channel)

    Whatsapp::WebhookSubscriptionHealthService.new(channel).perform
  end

  private

  def eligible_channel?(channel)
    channel.provider == 'whatsapp_cloud' && channel.account.active? &&
      channel.inbox.present? && channel.inbox.deleting_at.nil?
  end
end
