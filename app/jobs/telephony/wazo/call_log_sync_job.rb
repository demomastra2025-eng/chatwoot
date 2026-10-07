# frozen_string_literal: true

class Telephony::Wazo::CallLogSyncJob < ApplicationJob
  queue_as :low

  def perform
    return unless ActiveModel::Type::Boolean.new.cast(ENV.fetch('TELEPHONY_WAZO_CALL_LOG_SYNC_ENABLED', nil))

    Telephony::ProviderConnection.where(provider_kind: 'wazo', status: 'active')
                                 .find_each do |connection|
      next unless connection.metadata.to_h['wazo_call_log_sync_enabled'] == true

      Telephony::Wazo::CallLogSyncService.new(connection: connection).perform
    rescue StandardError => e
      Rails.logger.warn("WAZO_CDR_SYNC_FAILED connection_id=#{connection.id} error_class=#{e.class.name}")
    end
  end
end
