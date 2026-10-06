# frozen_string_literal: true

class Meta::ChannelCredentialHealthRecorder
  WHATSAPP_ACTION_REQUIRED_STATUSES = Whatsapp::TokenInspectionService::REAUTHORIZATION_STATUSES.freeze

  def initialize(channel)
    @channel = channel
  end

  def record_result!(result)
    persist!(
      status: persisted_status(result.status, result.metadata),
      reason: result.reason,
      error: result.error,
      metadata: result.metadata
    )
  end

  def record_whatsapp_token_health!(token_health)
    metadata = token_health.to_h.deep_stringify_keys
    provider_status = metadata['status'].to_s
    status = if WHATSAPP_ACTION_REQUIRED_STATUSES.include?(provider_status)
               'action_required'
             elsif provider_status == Whatsapp::TokenInspectionService::EXPIRING_SOON_STATUS
               'expiring'
             elsif provider_status == Whatsapp::TokenInspectionService::HEALTHY_STATUS
               'healthy'
             elsif provider_status == Whatsapp::TokenInspectionService::HEALTHY_UNVERIFIED_STATUS
               'degraded'
             else
               'transient_failure'
             end

    persist!(
      status: status,
      reason: provider_status.presence || 'unknown',
      error: metadata['error'],
      metadata: metadata.except('error')
    )
  end

  private

  def persist!(status:, reason:, error:, metadata:)
    health = find_or_create_health
    secrets = Meta::CredentialDataSanitizer.channel_secrets(@channel)
    safe_metadata = Meta::CredentialDataSanitizer.sanitize(metadata.to_h.deep_stringify_keys, secrets: secrets)
    safe_error = Meta::CredentialDataSanitizer.sanitize(error.to_h.deep_stringify_keys, secrets: secrets)
    now = Time.current

    health.with_lock do
      health.update!(
        health_attributes(status, reason, safe_metadata)
          .merge(provider_error_attributes(safe_error))
          .merge(health_history_attributes(health, status, now))
      )
    end
    health
  end

  def health_attributes(status, reason, metadata)
    {
      account_id: @channel.account_id,
      status: status,
      reason: reason,
      expires_at: parsed_time(metadata['expires_at']),
      data_access_expires_at: parsed_time(metadata['data_access_expires_at']),
      checked_at: parsed_time(metadata['checked_at']) || Time.current,
      metadata: metadata
    }
  end

  def provider_error_attributes(error)
    {
      provider_code: error['code'],
      provider_subcode: error['error_subcode'],
      provider_type: error['type'],
      provider_trace_id: error['fbtrace_id']
    }
  end

  def health_history_attributes(health, status, now)
    successful = successful_status?(status)
    {
      consecutive_failures: successful ? 0 : health.consecutive_failures.to_i + 1,
      last_healthy_at: successful ? now : health.last_healthy_at,
      last_failed_at: successful ? health.last_failed_at : now
    }
  end

  def find_or_create_health
    Meta::ChannelCredentialHealth.find_or_create_by!(channel: @channel) do |health|
      health.account_id = @channel.account_id
    end
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def persisted_status(status, metadata)
    return 'expiring' if status.to_s == 'healthy' && expiring_soon?(metadata.to_h['expires_at'])

    status.to_s
  end

  def expiring_soon?(value)
    expires_at = parsed_time(value)
    expires_at.present? && expires_at > Time.current && expires_at <= 10.days.from_now
  end

  def successful_status?(status)
    %w[healthy expiring].include?(status)
  end

  def parsed_time(value)
    return value if value.respond_to?(:in_time_zone)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
