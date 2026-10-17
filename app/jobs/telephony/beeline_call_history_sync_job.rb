# frozen_string_literal: true

class Telephony::BeelineCallHistorySyncJob < ApplicationJob
  queue_as :low

  def perform(channel_id: nil, subscribe_webhook: :auto)
    if channel_id.present?
      channel = Channel::Voice.find_by(id: channel_id, provider: 'beeline')
      return if channel.blank?

      sync_channel(channel, subscribe_webhook: subscribe_webhook)
      return
    end

    Channel::Voice.where(provider: 'beeline').includes(:inbox).find_each do |channel|
      next unless sync_enabled_for_channel?(channel)
      next unless Telephony::Beeline::ApiClient.for_channel(channel).configured?

      sync_channel(channel, subscribe_webhook: subscribe_webhook)
    end
  end

  private

  def sync_enabled_for_channel?(channel)
    cfg = channel.provider_config_hash
    return true unless cfg.key?('beeline_sync_enabled')

    ActiveModel::Type::Boolean.new.cast(cfg['beeline_sync_enabled'])
  end

  def sync_channel(channel, subscribe_webhook: :auto)
    Telephony::Beeline::CallHistorySyncService.new(
      channel: channel,
      subscribe_webhook: subscribe_webhook
    ).perform
  rescue StandardError => e
    Rails.logger.warn(
      "TELEPHONY_BEELINE_CDR_SYNC_FAILED channel_id=#{channel.id} " \
      "error_class=#{e.class.name} message=#{e.message}"
    )
  end
end
