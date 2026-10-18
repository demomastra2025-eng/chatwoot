# frozen_string_literal: true

class Telephony::BinotelCallHistorySyncJob < ApplicationJob
  queue_as :low

  def perform(channel_id: nil)
    if channel_id.present?
      channel = Channel::Voice.find_by(id: channel_id, provider: 'binotel')
      return if channel.blank?

      sync_channel(channel)
      return
    end

    Channel::Voice.where(provider: 'binotel').includes(:inbox).find_each do |channel|
      next unless sync_enabled_for_channel?(channel)
      next unless Telephony::Binotel::ApiClient.for_channel(channel).configured?

      sync_channel(channel)
    end
  end

  private

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
