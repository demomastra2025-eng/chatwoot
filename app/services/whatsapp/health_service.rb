class Whatsapp::HealthService
  BASE_URI = 'https://graph.facebook.com'.freeze

  def initialize(channel)
    @channel = channel
    @access_token = channel.provider_config['api_key']
    @api_version = GlobalConfigService.load('WHATSAPP_API_VERSION', 'v25.0')
  end

  def fetch_health_status
    validate_channel!
    fetch_phone_health_data
  end

  private

  def validate_channel!
    raise ArgumentError, 'Channel is required' if @channel.blank?
    raise ArgumentError, 'API key is missing' if @access_token.blank?
    raise ArgumentError, 'Phone number ID is missing' if @channel.provider_config['phone_number_id'].blank?
  end

  def fetch_phone_health_data
    phone_number_id = @channel.provider_config['phone_number_id']

    response = HTTParty.get(
      "#{BASE_URI}/#{@api_version}/#{phone_number_id}",
      headers: { 'Authorization' => "Bearer #{@access_token}" },
      query: {
        fields: health_fields
      }.merge(graph_api_query)
    )

    handle_response(response)
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP HEALTH] Error fetching health data: #{safe_provider_data(e.message)}"
    raise
  end

  def health_fields
    %w[
      id
      quality_rating
      whatsapp_business_manager_messaging_limit
      code_verification_status
      account_mode
      display_phone_number
      name_status
      verified_name
      webhook_configuration
      throughput
      last_onboarded_time
      platform_type
      certificate
    ].join(',')
  end

  def graph_api_query
    Whatsapp::FacebookApiClient.appsecret_proof_query(@access_token)
  end

  def handle_response(response)
    unless response.success?
      error_payload = response.parsed_response if response.respond_to?(:parsed_response)
      @channel.record_provider_authorization_error!(error_payload) if @channel.respond_to?(:record_provider_authorization_error!)
      raise "WhatsApp API request failed: #{response.code} - #{safe_provider_data(response.body)}"
    end

    data = response.parsed_response
    formatted_response = format_health_response(data)
    clear_authorization_failure_if_healthy(formatted_response)
    formatted_response
  end

  def format_health_response(response)
    {
      id: response['id'],
      display_phone_number: response['display_phone_number'],
      verified_name: response['verified_name'],
      name_status: response['name_status'],
      quality_rating: response['quality_rating'],
      messaging_limit: response['whatsapp_business_manager_messaging_limit'],
      account_mode: response['account_mode'],
      code_verification_status: response['code_verification_status'],
      webhook_configuration: response['webhook_configuration'],
      expected_webhook_url: build_expected_webhook_url,
      throughput: response['throughput'],
      last_onboarded_time: response['last_onboarded_time'],
      platform_type: response['platform_type'],
      certificate: response['certificate'],
      business_id: @channel.provider_config['business_id'].presence || @channel.provider_config['business_account_id']
    }
  end

  def build_expected_webhook_url
    @channel.callback_webhook_url if ENV.fetch('FRONTEND_URL', nil).present?
  end

  def safe_provider_data(data)
    secrets = Meta::CredentialDataSanitizer.channel_secrets(@channel)
    Meta::CredentialDataSanitizer.sanitize(data.to_s.first(1000), secrets: secrets)
  end

  def clear_authorization_failure_if_healthy(health_data)
    return unless @channel.respond_to?(:reauthorization_required?) && @channel.reauthorization_required?
    return unless @channel.respond_to?(:provider_authorization_error_recorded?) && @channel.provider_authorization_error_recorded?
    return if channel_in_pending_state?(health_data)

    @channel.reauthorized!
    @channel.clear_provider_authorization_error! if @channel.respond_to?(:clear_provider_authorization_error!)
  end

  def channel_in_pending_state?(health_data)
    health_data[:platform_type] == 'NOT_APPLICABLE' ||
      health_data.dig(:throughput, 'level') == 'NOT_APPLICABLE'
  end
end
