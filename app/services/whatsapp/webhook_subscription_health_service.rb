require 'digest'

class Whatsapp::WebhookSubscriptionHealthService
  class CheckError < StandardError; end

  def initialize(channel)
    @channel = channel
  end

  def perform
    snapshot = inspection_snapshot
    return :skipped if snapshot.blank?

    api_client = Whatsapp::FacebookApiClient.new(snapshot[:access_token])
    if api_client.app_subscribed_to_waba?(snapshot[:waba_id])
      Rails.logger.info("[WHATSAPP WEBHOOK SUBSCRIPTION] Healthy channel=#{@channel.id}")
      return :healthy
    end

    repair_result = repair_subscription!(snapshot)
    return :healthy if repair_result == :healthy

    Rails.logger.warn("[WHATSAPP WEBHOOK SUBSCRIPTION] Repaired channel=#{@channel.id}")
    :repaired
  rescue ActiveRecord::RecordNotFound, Whatsapp::WebhookSetupService::StaleRecoveryIdentityError
    raise
  rescue StandardError => e
    safe_message = sanitized_error_message(e)
    Rails.logger.error(
      "[WHATSAPP WEBHOOK SUBSCRIPTION] Check failed channel=#{@channel&.id}: #{e.class}: #{safe_message}"
    )
    raise CheckError, safe_message
  end

  private

  def inspection_snapshot
    @channel.with_lock do
      @channel.reload
      next unless eligible_channel?

      config = @channel.provider_config.to_h
      waba_id = config['business_account_id']
      access_token = config['api_key']
      next if waba_id.blank? || access_token.blank?

      {
        waba_id: waba_id,
        access_token: access_token,
        credential_fingerprint: credential_fingerprint(waba_id, access_token)
      }
    end
  end

  def eligible_channel?
    @channel.provider == 'whatsapp_cloud' && @channel.account.active? &&
      @channel.inbox.present? && @channel.inbox.deleting_at.nil?
  end

  def repair_subscription!(snapshot)
    Whatsapp::WebhookSetupService.new(
      @channel,
      snapshot[:waba_id],
      snapshot[:access_token],
      strict: true,
      expected_credential_fingerprint: snapshot[:credential_fingerprint]
    ).register_callback_if_missing
  end

  def credential_fingerprint(waba_id, access_token)
    Digest::SHA256.hexdigest([waba_id, access_token].map(&:to_s).join("\0"))
  end

  def sanitized_error_message(error)
    Meta::CredentialDataSanitizer.sanitize(
      error.message.to_s.first(5000),
      secrets: Meta::CredentialDataSanitizer.channel_secrets(@channel)
    )
  end
end
