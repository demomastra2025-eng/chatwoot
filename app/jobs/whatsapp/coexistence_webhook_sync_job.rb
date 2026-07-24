class Whatsapp::CoexistenceWebhookSyncJob < MutexApplicationJob
  CHANNEL_LOCK_TIMEOUT = 30.minutes

  queue_as :whatsappweb_history

  retry_on LockAcquisitionError, wait: 1.second, attempts: 8
  retry_on Whatsapp::WabaLock::LockAcquisitionError, wait: 1.second, attempts: 8
  retry_on Whatsapp::CoexistenceHistoryService::MediaHydrationError, wait: :polynomially_longer, attempts: 8 do |job, error|
    channel = Channel::Whatsapp.find_by(id: job.arguments.first)
    context = job.arguments.fourth.to_h.with_indifferent_access
    if channel.present? && context[:business_account_id].present? && context[:sync_generation].present?
      Whatsapp::WabaLock.new(context[:business_account_id]).with_lock do
        channel.reload
        next unless Whatsapp::CoexistenceWebhookSyncJob.valid_recovery_identity?(channel, context)

        Whatsapp::CoexistenceSyncReconciliationService.new(channel)
                                                      .require_manual_recovery!(error, generation: context[:sync_generation])
      end
    end
  end
  discard_on ActiveRecord::RecordNotFound

  def self.valid_recovery_identity?(channel, context)
    valid_recovery_channel?(channel) && recovery_identity_matches?(channel, context)
  end

  def self.valid_recovery_channel?(channel)
    channel.provider == 'whatsapp_cloud' && channel.account&.active? && channel.inbox.present? &&
      channel.inbox.deleting_at.nil?
  end

  def self.recovery_identity_matches?(channel, context)
    config = channel.provider_config.to_h
    config['embedded_signup_flow'] == 'coexistence' &&
      config['business_account_id'].to_s == context[:business_account_id].to_s &&
      config.dig('coexistence_sync', 'generation').to_s == context[:sync_generation].to_s
  end

  def perform(channel_id, field, value, routing_context = {})
    channel = Channel::Whatsapp.find(channel_id)
    context = routing_context.with_indifferent_access
    return if context[:business_account_id].blank?

    Whatsapp::WabaLock.new(context[:business_account_id]).with_lock do
      with_lock("whatsapp-coexistence-webhook-sync-#{channel_id}", CHANNEL_LOCK_TIMEOUT) do
        channel.reload
        dispatch(channel, field, value.with_indifferent_access, context) if valid_routing_context?(channel, context)
      end
    end
  end

  private

  def valid_routing_context?(channel, context)
    valid_channel?(channel) && waba_matches?(channel, context) && generation_matches?(channel, context) &&
      provider_event_matches_generation?(channel, context) && metadata_matches?(channel, context[:metadata])
  end

  def valid_channel?(channel)
    channel.provider == 'whatsapp_cloud' &&
      channel.account.active? &&
      channel.inbox.present? && channel.inbox.deleting_at.nil? &&
      channel.provider_config.to_h['embedded_signup_flow'] == 'coexistence'
  end

  def waba_matches?(channel, context)
    context[:business_account_id].present? &&
      channel.provider_config['business_account_id'].to_s == context[:business_account_id].to_s
  end

  def generation_matches?(channel, context)
    context[:sync_generation].present? &&
      channel.provider_config.dig('coexistence_sync', 'generation').to_s == context[:sync_generation].to_s
  end

  def provider_event_matches_generation?(channel, context)
    raw_event_at = context[:provider_event_at]
    onboarded_at = Time.zone.parse(channel.provider_config.dig('coexistence_sync', 'onboarded_at').to_s)
    return true if raw_event_at.blank? || onboarded_at.blank?
    return false unless raw_event_at.to_s.match?(/\A\d+\z/)

    event_epoch = raw_event_at.to_i
    event_epoch /= 1000 if event_epoch >= 1_000_000_000_000
    event_epoch >= onboarded_at.to_i
  rescue ArgumentError
    false
  end

  def metadata_matches?(channel, raw_metadata)
    metadata = raw_metadata.to_h.with_indifferent_access
    return unique_metadata_free_channel?(channel) if metadata.empty?
    return false unless metadata[:phone_number_id].present? && metadata[:display_phone_number].present?
    return false unless channel.provider_config['phone_number_id'].to_s == metadata[:phone_number_id].to_s

    channel.phone_number == "+#{metadata[:display_phone_number].to_s.delete_prefix('+')}"
  end

  def unique_metadata_free_channel?(channel)
    waba_id = channel.provider_config.to_h['business_account_id'].to_s
    return false unless Channel::Whatsapp.unambiguous_waba_owner_account_id(waba_id) == channel.account_id

    channels = Channel::Whatsapp.active_cloud.for_waba(waba_id).where(account_id: channel.account_id)
    channel_ids = channels.where("provider_config ->> 'embedded_signup_flow' = 'coexistence'").limit(2).pluck(:id)
    channel_ids.one? && channel_ids.first == channel.id
  end

  def dispatch(channel, field, value, context)
    case field
    when 'history'
      Whatsapp::CoexistenceHistoryService.new(channel: channel, value: value).perform
    when 'smb_app_state_sync'
      Whatsapp::CoexistenceContactSyncService.new(channel: channel, value: value).perform
    else
      raise ArgumentError, "Unsupported coexistence webhook field: #{field}"
    end

    Whatsapp::CoexistenceSyncReconciliationService.new(channel)
                                                  .reconcile_webhook!(field, generation: context[:sync_generation])
  end
end
