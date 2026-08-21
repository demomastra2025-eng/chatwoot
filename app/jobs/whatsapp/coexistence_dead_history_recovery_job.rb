class Whatsapp::CoexistenceDeadHistoryRecoveryJob < MutexApplicationJob
  class InvalidRecoveryPayloadError < StandardError; end
  class EnqueueError < StandardError; end

  RECOVERABLE_ERROR_CLASSES = [
    'Whatsapp::WabaLock::LockAcquisitionError',
    'MutexApplicationJob::LockAcquisitionError'
  ].freeze
  RECOVERY_INTERVAL = 5.seconds
  RECOVERY_LOCK_TIMEOUT = 30.minutes

  queue_as :whatsappweb_history

  class << self
    def start(channel_id)
      channel = Channel::Whatsapp.find(channel_id)
      new.send(:validate_target_channel!, channel)
      raise InvalidRecoveryPayloadError, "No recoverable history payloads for channel #{channel.id}" unless pending_payload?(channel)

      perform_later(channel.id)
    end

    def pending_payload?(channel)
      new.send(:matching_dead_job, channel).present?
    end
  end

  retry_on Whatsapp::WabaLivePriority::LiveTrafficPendingError, wait: 15.seconds, attempts: :unlimited, jitter: 0.5
  retry_on MutexApplicationJob::LockAcquisitionError, wait: 15.seconds, attempts: :unlimited, jitter: 0.5
  retry_on Whatsapp::WabaLock::LockAcquisitionError, wait: 15.seconds, attempts: :unlimited, jitter: 0.5
  retry_on Whatsapp::CoexistenceHistoryService::MediaHydrationError, wait: :polynomially_longer, attempts: 8
  discard_on ActiveRecord::RecordNotFound

  def perform(channel_id)
    channel = Channel::Whatsapp.find(channel_id)
    validate_target_channel!(channel)
    waba_id = channel.provider_config['business_account_id'].to_s
    result = :complete

    with_lock(recovery_lock_key(channel, waba_id), RECOVERY_LOCK_TIMEOUT) do
      dead_job = matching_dead_job(channel)
      next if dead_job.blank?

      arguments = serialized_arguments(dead_job)
      context = recovery_context(channel)
      dispatched = Whatsapp::CoexistenceWebhookSyncJob.new.perform(channel.id, 'history', arguments.third, context)
      raise InvalidRecoveryPayloadError, 'Dead history payload was not dispatched' unless dispatched

      enqueue_next!(channel)
      dead_job.delete
      result = :replayed
    end
    result
  end

  private

  def matching_dead_job(channel)
    require 'sidekiq/api'

    Sidekiq::DeadSet.new.find do |dead_job|
      recoverable_dead_job?(dead_job) && provider_identity_matches?(channel, serialized_arguments(dead_job).fourth)
    end
  end

  def recoverable_dead_job?(dead_job)
    arguments = serialized_arguments(dead_job)
    dead_job.display_class == 'Whatsapp::CoexistenceWebhookSyncJob' &&
      RECOVERABLE_ERROR_CLASSES.include?(dead_job.item['error_class'].to_s) &&
      arguments.size >= 4 && arguments.second.to_s == 'history' && arguments.third.is_a?(Hash)
  end

  def serialized_arguments(dead_job)
    Array(dead_job.args.first.to_h['arguments'])
  end

  def provider_identity_matches?(channel, raw_context)
    context = raw_context.to_h.with_indifferent_access
    return false unless routing_identity_matches?(channel, context)

    phone_identity_matches?(channel, context[:metadata])
  end

  def routing_identity_matches?(channel, context)
    account_matches = context[:account_id].blank? || context[:account_id].to_i == channel.account_id
    provider_matches = context[:provider].blank? || context[:provider].to_s == channel.provider
    account_matches && provider_matches &&
      context[:business_account_id].to_s == channel.provider_config['business_account_id'].to_s
  end

  def phone_identity_matches?(channel, raw_metadata)
    metadata = raw_metadata.to_h.with_indifferent_access
    queued_phone_id = metadata[:phone_number_id].to_s
    queued_phone = normalized_phone(metadata[:display_phone_number])
    return false if queued_phone_id.blank? || queued_phone.blank?

    queued_phone_id == channel.provider_config['phone_number_id'].to_s && queued_phone == normalized_phone(channel.phone_number)
  end

  def validate_target_channel!(channel)
    config = channel.provider_config.to_h
    return if eligible_channel?(channel, config) && complete_provider_identity?(channel, config)

    raise InvalidRecoveryPayloadError, "Channel #{channel.id} is not eligible for coexistence history recovery"
  end

  def eligible_channel?(channel, config)
    channel.provider == 'whatsapp_cloud' && config['embedded_signup_flow'] == 'coexistence' &&
      channel.account.active? && channel.inbox.present? && channel.inbox.deleting_at.nil?
  end

  def complete_provider_identity?(channel, config)
    config['business_account_id'].present? && config['phone_number_id'].present? && normalized_phone(channel.phone_number).present?
  end

  def enqueue_next!(channel)
    next_job = self.class.set(wait: RECOVERY_INTERVAL).perform_later(channel.id)
    return if next_job.successfully_enqueued?

    raise EnqueueError, "Could not enqueue the next history recovery job for channel #{channel.id}"
  end

  def recovery_lock_key(channel, waba_id)
    "whatsapp:coexistence:dead-history-recovery:#{channel.id}:#{waba_id}"
  end

  def recovery_context(channel)
    {
      account_id: channel.account_id,
      provider: channel.provider,
      business_account_id: channel.provider_config['business_account_id'],
      sync_generation: channel.provider_config.dig('coexistence_sync', 'generation'),
      metadata: {
        phone_number_id: channel.provider_config['phone_number_id'],
        display_phone_number: channel.phone_number.to_s.delete_prefix('+')
      }
    }
  end

  def normalized_phone(value)
    value.to_s.gsub(/\D/, '')
  end
end
