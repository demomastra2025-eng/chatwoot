class Whatsapp::TokenHealthCheckService
  def initialize(channel)
    @channel = channel
  end

  def perform
    return unless whatsapp_cloud_channel?

    token_health = inspect_token
    @channel.store_token_health!(token_health)
    apply_reauthorization_state(token_health)
    token_health
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP TOKEN HEALTH] Check failed for channel=#{@channel&.id}: #{e.class}: #{e.message}"
    token_health = failed_check_metadata(e)
    @channel.store_token_health!(token_health) if @channel.respond_to?(:store_token_health!)
    @channel.record_provider_configuration_error!(token_health.dig('error', 'message'), type: 'WhatsAppTokenHealth') if prompt_for_failed_check?(e)
    token_health
  end

  private

  def whatsapp_cloud_channel?
    @channel.is_a?(Channel::Whatsapp) && @channel.provider == 'whatsapp_cloud'
  end

  def inspect_token
    config = @channel.provider_config.to_h
    Whatsapp::TokenInspectionService.new(
      access_token: config['api_key'],
      waba_id: config['business_account_id'],
      phone_number_id: config['phone_number_id']
    ).perform
  end

  def apply_reauthorization_state(token_health)
    if reauthorization_required?(token_health)
      @channel.record_provider_configuration_error!(
        reauthorization_message(token_health),
        code: token_health.dig('error', 'code'),
        type: token_health.dig('error', 'type') || 'WhatsAppTokenHealth'
      )
    elsif @channel.provider_authorization_error_recorded?
      @channel.reauthorized! if @channel.respond_to?(:reauthorized!)
      @channel.clear_provider_authorization_error!
    end
  end

  def reauthorization_required?(token_health)
    Whatsapp::TokenInspectionService::REAUTHORIZATION_STATUSES.include?(token_health['status'])
  end

  def reauthorization_message(token_health)
    token_health.dig('error', 'message').presence ||
      "WhatsApp token health check failed: #{token_health['status']}"
  end

  def failed_check_metadata(error)
    {
      'status' => error.is_a?(ArgumentError) ? Whatsapp::TokenInspectionService::INVALID_STATUS : 'unknown',
      'checked_at' => Time.current.iso8601,
      'error' => {
        'type' => error.class.name,
        'message' => error.message
      }
    }
  end

  def prompt_for_failed_check?(error)
    error.is_a?(ArgumentError) && @channel.respond_to?(:record_provider_configuration_error!)
  end
end
