module Webhooks::WhatsappLifecycleEventHelpers
  def trusted_lifecycle_update?(channel, hmac_verified)
    return true if hmac_verified && (channel.blank? || channel.provider == 'whatsapp_cloud')

    Rails.logger.warn(
      "[WHATSAPP LIFECYCLE] ignored untrusted event channel=#{channel&.id || 'none'} " \
      "provider=#{channel&.provider || 'none'} hmac_verified=#{hmac_verified}"
    )
    false
  end

  def handle_lifecycle_updates(channel, field, params)
    lifecycle_channels(channel, field, params).find_each do |lifecycle_channel|
      Whatsapp::LifecycleWebhookService.new(channel: lifecycle_channel, field: field, params: params).perform
    end
  end

  private

  def lifecycle_channels(channel, field, params)
    return Channel::Whatsapp.where(id: channel.id) if field == 'user_preferences' && channel.present?

    account_update_channels(params)
  end
end
