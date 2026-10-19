# frozen_string_literal: true

class Telephony::BinotelCallHistorySyncJob < ApplicationJob
  queue_as :low

  LOCK_TTL = 90.seconds
  LOCK_KEY_PREFIX = 'TELEPHONY::BINOTEL_CALL_HISTORY_SYNC_MUTEX'

  def perform(channel_id: nil)
    if channel_id.present?
      channel = Channel::Voice.find_by(id: channel_id, provider: 'binotel')
      return if channel.blank?
      return unless sync_enabled_for_channel?(channel)
      return unless Telephony::Binotel::ApiClient.for_channel(channel).configured?

      with_channel_lock(channel.id) do
        sync_channel(channel)
      end
      return
    end

    Channel::Voice.where(provider: 'binotel').find_each do |channel|
      next unless sync_enabled_for_channel?(channel)
      next unless Telephony::Binotel::ApiClient.for_channel(channel).configured?

      self.class.perform_later(channel_id: channel.id)
    end
  end

  private

  def with_channel_lock(channel_id)
    lock_key = "#{LOCK_KEY_PREFIX}::#{channel_id}"
    lock_manager = Redis::LockManager.new
    return unless lock_manager.lock(lock_key, LOCK_TTL)

    begin
      yield
    ensure
      lock_manager.unlock(lock_key)
    end
  end

  def sync_enabled_for_channel?(channel)
    cfg = channel.provider_config_hash
    return true unless cfg.key?('binotel_sync_enabled')

    ActiveModel::Type::Boolean.new.cast(cfg['binotel_sync_enabled'])
  end

  def sync_channel(channel)
    Telephony::Binotel::CallHistorySyncService.new(channel: channel).perform
  rescue StandardError => e
    Rails.logger.warn(
      "TELEPHONY_BINOTEL_CDR_SYNC_FAILED channel_id=#{channel.id} " \
      "error_class=#{e.class.name} message=#{e.message}"
    )
  end
end
