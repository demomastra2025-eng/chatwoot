require 'digest'

class Whatsapp::TokenHealthCheckService
  def initialize(channel)
    @channel = channel
  end

  def perform
    return unless whatsapp_cloud_channel?

    inspection_snapshot = nil
    inspection_snapshot = current_inspection_snapshot
    token_health = sanitized_token_health(perform_token_inspection(inspection_snapshot[:context]))

    persist_token_health_if_current!(token_health, inspection_snapshot)
    token_health
  rescue StandardError => e
    safe_message = sanitized_error_message(e)
    Rails.logger.error "[WHATSAPP TOKEN HEALTH] Check failed for channel=#{@channel&.id}: #{e.class}: #{safe_message}"
    token_health = sanitized_token_health(failed_check_metadata(e, safe_message))
    persist_token_health_if_current!(token_health, inspection_snapshot) if inspection_snapshot
    token_health
  end

  private

  def whatsapp_cloud_channel?
    @channel.is_a?(Channel::Whatsapp) && @channel.provider == 'whatsapp_cloud'
  end

  def current_inspection_context
    config = @channel.provider_config.to_h
    {
      access_token: config['api_key'],
      waba_id: config['business_account_id'],
      phone_number_id: config['phone_number_id']
    }
  end

  def current_inspection_snapshot
    @channel.with_lock do
      @channel.reload
      context = current_inspection_context
      {
        context: context,
        credential_fingerprint: credential_fingerprint(context),
        authorization_error_fingerprint: current_authorization_error_fingerprint
      }
    end
  end

  def perform_token_inspection(context)
    inspection_service = Whatsapp::TokenInspectionService.new(
      access_token: context[:access_token],
      waba_id: context[:waba_id],
      phone_number_id: context[:phone_number_id]
    )
    inspection_service.perform
  end

  def persist_token_health_if_current!(token_health, inspection_snapshot)
    applied = @channel.with_lock do
      @channel.reload
      next false unless credential_fingerprint(current_inspection_context) == inspection_snapshot[:credential_fingerprint]

      @channel.store_token_health!(token_health)
      Meta::ChannelCredentialHealthRecorder.new(@channel).record_whatsapp_token_health!(token_health)
      apply_reauthorization_state(token_health, inspection_snapshot[:authorization_error_fingerprint])
      true
    end

    Rails.logger.info("[WHATSAPP TOKEN HEALTH] Ignored stale result for channel #{@channel.id}") unless applied
    applied
  end

  def credential_fingerprint(context)
    credential_identity = [context[:access_token], context[:waba_id], context[:phone_number_id]]
    Digest::SHA256.hexdigest(credential_identity.map(&:to_s).join("\0"))
  end

  def current_authorization_error_fingerprint
    config = @channel.provider_config.to_h
    authorization_state = [config['authorization_status'], config['authorization_error']]
    return if authorization_state.all?(&:blank?)

    Digest::SHA256.hexdigest(authorization_state.to_json)
  end

  def apply_reauthorization_state(token_health, inspected_authorization_error_fingerprint)
    return unless current_authorization_error_fingerprint == inspected_authorization_error_fingerprint

    if reauthorization_required?(token_health)
      @channel.record_provider_configuration_error!(
        reauthorization_message(token_health),
        code: token_health.dig('error', 'code'),
        type: token_health.dig('error', 'type') || 'WhatsAppTokenHealth'
      )
    elsif explicitly_healthy?(token_health) &&
          @channel.provider_authorization_error_recorded?
      @channel.reauthorized! if @channel.respond_to?(:reauthorized!)
      @channel.clear_provider_authorization_error!
    end
  end

  def reauthorization_required?(token_health)
    Whatsapp::TokenInspectionService::REAUTHORIZATION_STATUSES.include?(token_health['status'])
  end

  def explicitly_healthy?(token_health)
    [
      Whatsapp::TokenInspectionService::HEALTHY_STATUS,
      Whatsapp::TokenInspectionService::HEALTHY_UNVERIFIED_STATUS
    ].include?(token_health['status'])
  end

  def reauthorization_message(token_health)
    token_health.dig('error', 'message').presence ||
      "WhatsApp token health check failed: #{token_health['status']}"
  end

  def failed_check_metadata(error, safe_message)
    {
      'status' => error.is_a?(ArgumentError) ? Whatsapp::TokenInspectionService::INVALID_STATUS : 'unknown',
      'checked_at' => Time.current.iso8601,
      'error' => {
        'type' => error.class.name,
        'message' => safe_message
      }
    }
  end

  def sanitized_token_health(token_health)
    secrets = Meta::CredentialDataSanitizer.channel_secrets(@channel)
    Meta::CredentialDataSanitizer.sanitize(token_health.to_h.deep_stringify_keys, secrets: secrets)
  end

  def sanitized_error_message(error)
    secrets = Meta::CredentialDataSanitizer.channel_secrets(@channel)
    Meta::CredentialDataSanitizer.sanitize(error.message.to_s, secrets: secrets)
  end

end
