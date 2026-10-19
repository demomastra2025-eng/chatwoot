# frozen_string_literal: true

class Telephony::Wazo::CallLogSyncJob < ApplicationJob
  queue_as :low

  LOCK_TTL = 90.seconds
  LOCK_KEY_PREFIX = 'TELEPHONY::WAZO_CALL_LOG_SYNC_MUTEX'

  def perform(connection_id: nil)
    return unless global_sync_enabled?

    if connection_id.present?
      connection = Telephony::ProviderConnection.find_by(id: connection_id, provider_kind: 'wazo', status: 'active')
      return if connection.blank?
      return unless sync_enabled_for_connection?(connection)

      with_connection_lock(connection.id) do
        sync_connection(connection)
      end
      return
    end

    Telephony::ProviderConnection.where(provider_kind: 'wazo', status: 'active').find_each do |active_connection|
      next unless sync_enabled_for_connection?(connection)

      self.class.perform_later(connection_id: active_connection.id)
    end
  end

  private

  def global_sync_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('TELEPHONY_WAZO_CALL_LOG_SYNC_ENABLED', nil))
  end

  def sync_enabled_for_connection?(connection)
    connection.metadata.to_h['wazo_call_log_sync_enabled'] == true
  end

  def with_connection_lock(connection_id)
    lock_key = "#{LOCK_KEY_PREFIX}::#{connection_id}"
    lock_manager = Redis::LockManager.new
    return unless lock_manager.lock(lock_key, LOCK_TTL)

    begin
      yield
    ensure
      lock_manager.unlock(lock_key)
    end
  end

  def sync_connection(connection)
    Telephony::Wazo::CallLogSyncService.new(connection: connection).perform
  rescue StandardError => e
    Rails.logger.warn("WAZO_CDR_SYNC_FAILED connection_id=#{connection.id} error_class=#{e.class.name}")
  end
end
