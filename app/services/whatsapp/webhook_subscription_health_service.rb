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
    return ensure_healthy_route!(snapshot) if api_client.app_subscribed_to_waba?(snapshot[:waba_id])

    repair_result = repair_subscription!(snapshot)
    return :healthy if repair_result == :healthy

    Rails.logger.warn("[WHATSAPP WEBHOOK SUBSCRIPTION] Repaired channel=#{@channel.id}")
    :repaired
  rescue ActiveRecord::RecordNotFound, Whatsapp::WebhookSetupService::StaleRecoveryIdentityError
    raise
  rescue Whatsapp::FacebookApiClient::Error => e
    authorization_result = handle_authorization_error(e, snapshot)
    return authorization_result if authorization_result

    raise_check_error(e)
  rescue StandardError => e
    raise_check_error(e)
  end

  private

  def ensure_healthy_route!(snapshot)
    setup_service(snapshot).ensure_remote_route!
    Rails.logger.info("[WHATSAPP WEBHOOK SUBSCRIPTION] Healthy channel=#{@channel.id}")
    :healthy
  end

  def handle_authorization_error(error, snapshot)
    classification = Meta::AuthorizationErrorClassifier.classify(error.payload, http_status: error.status)
    return unless classification.kind == :reauthorization_required

    Whatsapp::WabaLock.new(snapshot[:waba_id]).with_lock do
      @channel.reload
      recorded = @channel.record_provider_authorization_error_if_current!(
        classification.error,
        expected_credential_fingerprint: snapshot[:credential_fingerprint]
      )
      authorization_error_result(recorded, classification.error)
    end
  rescue Whatsapp::WabaLock::LockAcquisitionError
    Rails.logger.info("[WHATSAPP WEBHOOK SUBSCRIPTION] Deferred authorization error channel=#{@channel.id}: authorization lock busy")
    :skipped
  end

  def authorization_error_result(recorded, error)
    unless recorded
      Rails.logger.info("[WHATSAPP WEBHOOK SUBSCRIPTION] Ignored stale authorization error channel=#{@channel.id}")
      return :skipped
    end

    Rails.logger.warn(
      "[WHATSAPP WEBHOOK SUBSCRIPTION] Reauthorization required channel=#{@channel.id} code=#{error['code']}"
    )
    :reauthorization_required
  end

  def raise_check_error(error)
    safe_message = sanitized_error_message(error)
    Rails.logger.error(
      "[WHATSAPP WEBHOOK SUBSCRIPTION] Check failed channel=#{@channel&.id}: #{error.class}: #{safe_message}"
    )
    raise CheckError, safe_message
  end

  def inspection_snapshot
    @channel.with_lock do
      @channel.reload
      next unless eligible_channel?
      next if @channel.provider_authorization_error_recorded?

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
    setup_service(snapshot).register_callback_if_missing
  end

  def setup_service(snapshot)
    Whatsapp::WebhookSetupService.new(
      @channel,
      snapshot[:waba_id],
      snapshot[:access_token],
      strict: true,
      expected_credential_fingerprint: snapshot[:credential_fingerprint]
    )
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
