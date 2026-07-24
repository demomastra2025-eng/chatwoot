class Whatsapp::WebhookCallbackReconciliationJob < ApplicationJob
  queue_as :default

  retry_on Whatsapp::WabaLock::LockAcquisitionError,
           Whatsapp::FacebookApiClient::WebhookRecoveryAnchorRequiredError,
           Whatsapp::WebhookSetupService::CallbackSetupError,
           wait: :polynomially_longer,
           attempts: 8 do |job, error|
    channel = Channel::Whatsapp.find_by(id: job.arguments.first)
    waba_id = job.arguments.second
    generation = job.arguments.third
    if Whatsapp::WebhookCallbackReconciliationJob.channel_eligible?(channel, waba_id, generation)
      Whatsapp::WebhookSetupService.new(channel, waba_id, nil, recovery_generation: generation)
                                   .require_manual_callback_recovery!(error)
    end
  end

  discard_on ActiveRecord::RecordNotFound
  discard_on Whatsapp::WebhookSetupService::StaleRecoveryIdentityError

  def perform(channel_id, waba_id, generation)
    channel = Channel::Whatsapp.find(channel_id)
    return unless self.class.channel_eligible?(channel, waba_id, generation)

    Whatsapp::WebhookSetupService.new(channel, waba_id, nil, recovery_generation: generation)
                                 .register_callback(schedule_recovery: false)
  end

  def self.channel_eligible?(channel, waba_id, generation)
    return false unless channel.present? && waba_id.present? && generation.present?

    active_callback_channel?(channel) && callback_identity_matches?(channel, waba_id, generation)
  end

  def self.active_callback_channel?(channel)
    channel.provider == 'whatsapp_cloud' && channel.account&.active? && channel.inbox.present? &&
      channel.inbox.deleting_at.nil?
  end

  def self.callback_identity_matches?(channel, waba_id, generation)
    config = channel.provider_config.to_h
    recovery = config[Whatsapp::WebhookCallbackRecoveryService::CONFIG_KEY].to_h
    config['business_account_id'].to_s == waba_id.to_s &&
      recovery['waba_id'].to_s == waba_id.to_s && recovery['generation'].to_s == generation.to_s &&
      Whatsapp::WebhookCallbackRecoveryService::ACTIVE_STATES.include?(recovery['state'])
  end
end
