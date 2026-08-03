require 'digest'

class Whatsapp::WebhookSubscriptionHealthCheckJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    seen_credentials = {}
    active_cloud_channels.find_each do |channel|
      provider_config = channel.provider_config.to_h
      waba_id = provider_config['business_account_id'].to_s
      fingerprint = Digest::SHA256.hexdigest(provider_config['api_key'].to_s)
      credential_key = [waba_id, fingerprint]
      next if waba_id.blank? || seen_credentials.key?(credential_key)

      seen_credentials[credential_key] = true
      Whatsapp::WebhookSubscriptionHealthCheckChannelJob.perform_later(channel.id)
    end
  end

  private

  def active_cloud_channels
    Channel::Whatsapp.active_cloud
                     .joins(:account)
                     .where(accounts: { status: Account.statuses[:active] })
  end
end
