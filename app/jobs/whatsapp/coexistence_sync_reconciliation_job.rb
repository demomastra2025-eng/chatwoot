class Whatsapp::CoexistenceSyncReconciliationJob < ApplicationJob
  WAIT_INTERVAL = 15.minutes

  queue_as :whatsappweb_history

  retry_on Whatsapp::WabaLock::LockAcquisitionError, wait: 1.second, attempts: 8
  discard_on ActiveRecord::RecordNotFound

  def perform(channel_id, generation)
    channel = Channel::Whatsapp.find(channel_id)
    waba_id = channel.provider_config['business_account_id']
    return unless self.class.channel_eligible?(channel, waba_id, generation)

    status = Whatsapp::WabaLock.new(waba_id).with_lock do
      channel.reload
      next :ineligible unless self.class.channel_eligible?(channel, waba_id, generation)

      Whatsapp::CoexistenceSyncReconciliationService.new(channel).reconcile_unknown_outcome!(generation: generation)
    end
    self.class.set(wait: WAIT_INTERVAL).perform_later(channel_id, generation) if status == :waiting
  end

  def self.channel_eligible?(channel, locked_waba_id, generation)
    locked_waba_id.present? && generation.present? && eligible_runtime?(channel) &&
      eligible_identity?(channel, locked_waba_id, generation)
  end

  def self.eligible_runtime?(channel)
    channel.provider == 'whatsapp_cloud' && channel.account&.active? &&
      channel.inbox.present? && channel.inbox.deleting_at.nil?
  end

  def self.eligible_identity?(channel, locked_waba_id, generation)
    config = channel.provider_config.to_h
    config['embedded_signup_flow'] == 'coexistence' &&
      config['business_account_id'].to_s == locked_waba_id.to_s &&
      config.dig('coexistence_sync', 'generation').to_s == generation.to_s
  end

  private_class_method :eligible_runtime?, :eligible_identity?
end
