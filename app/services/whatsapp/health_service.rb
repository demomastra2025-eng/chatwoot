class Whatsapp::HealthService
  BASE_URI = 'https://graph.facebook.com'.freeze
  class StaleProviderIdentityError < StandardError; end

  def initialize(channel)
    @channel = channel
    @api_version = GlobalConfigService.load('WHATSAPP_API_VERSION', 'v25.0')
  end

  def fetch_health_status
    validate_channel!
    @provider_snapshot = provider_snapshot
    validate_snapshot!
    @probe_started_at = Time.current
    fetch_phone_health_data
  end

  private

  def validate_channel!
    raise ArgumentError, 'Channel is required' if @channel.blank?
  end

  def validate_snapshot!
    raise ArgumentError, 'API key is missing' if @provider_snapshot[:access_token].blank?
    raise ArgumentError, 'Phone number ID is missing' if @provider_snapshot[:phone_number_id].blank?
  end

  def fetch_phone_health_data
    phone_number_id = @provider_snapshot[:phone_number_id]
    access_token = @provider_snapshot[:access_token]

    response = HTTParty.get(
      "#{BASE_URI}/#{@api_version}/#{phone_number_id}",
      headers: { 'Authorization' => "Bearer #{access_token}" },
      query: {
        fields: health_fields
      }.merge(graph_api_query(access_token))
    )

    with_current_provider_snapshot { handle_response(response) }
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

  def graph_api_query(access_token)
    Whatsapp::FacebookApiClient.appsecret_proof_query(access_token)
  end

  def provider_snapshot
    @channel.with_lock do
      @channel.reload
      config = @channel.provider_config.to_h
      {
        access_token: config['api_key'],
        waba_id: config['business_account_id'],
        phone_number_id: config['phone_number_id']
      }
    end
  end

  def with_current_provider_snapshot
    Whatsapp::WabaLock.with_locks([@provider_snapshot[:waba_id]]) do
      @channel.reload
      raise StaleProviderIdentityError, 'WhatsApp health credentials changed during request' unless provider_snapshot_current?

      yield
    end
  end

  def provider_snapshot_current?
    config = @channel.provider_config.to_h
    current = [config['api_key'], config['business_account_id'], config['phone_number_id']].map(&:to_s)
    expected = @provider_snapshot.values_at(:access_token, :waba_id, :phone_number_id).map(&:to_s)
    current == expected
  end

  def handle_response(response)
    unless response.success?
      error_payload = response.parsed_response if response.respond_to?(:parsed_response)
      @channel.record_provider_authorization_error!(error_payload) if @channel.respond_to?(:record_provider_authorization_error!)
      raise "WhatsApp API request failed: #{response.code} - #{safe_provider_data(response.body)}"
    end

    data = response.parsed_response
    formatted_response = format_health_response(data)
    reconcile_phone_registration(formatted_response)
    record_phone_registration_incomplete_if_pending(formatted_response)
    clear_authorization_failure_if_healthy(formatted_response)
    formatted_response[:phone_registration] = public_phone_registration_state
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
    secrets << @provider_snapshot[:access_token] if @provider_snapshot
    Meta::CredentialDataSanitizer.sanitize(data.to_s.first(1000), secrets: secrets)
  end

  def clear_authorization_failure_if_healthy(health_data)
    return unless @channel.respond_to?(:reauthorization_required?) && @channel.reauthorization_required?
    return unless @channel.respond_to?(:provider_authorization_error_recorded?) && @channel.provider_authorization_error_recorded?
    return if channel_in_pending_state?(health_data)

    @channel.reauthorized!
    @channel.clear_provider_authorization_error! if @channel.respond_to?(:clear_provider_authorization_error!)
  end

  def record_phone_registration_incomplete_if_pending(health_data)
    return unless channel_in_pending_state?(health_data)
    return if @channel.provider_config.to_h['embedded_signup_flow'] == 'coexistence'

    changed = @channel.with_lock do
      @channel.reload
      config = @channel.provider_config.to_h.deep_dup
      registration = config[Whatsapp::PhoneRegistrationService::CONFIG_KEY].to_h
      next false if preserve_registration_state?(registration)

      config[Whatsapp::PhoneRegistrationService::CONFIG_KEY] = registration.merge(
        'status' => 'registration_incomplete',
        'detected_at' => Time.current.iso8601
      )
      @channel.persist_provider_config_state!(config)
      true
    end
    @channel.inbox&.update_account_cache if changed
  end

  def reconcile_phone_registration(health_data)
    Whatsapp::PhoneRegistrationService.new(@channel).reconcile_from_health!(
      pending: channel_in_pending_state?(health_data),
      active: channel_in_active_state?(health_data),
      probe_started_at: @probe_started_at
    )
  end

  def public_phone_registration_state
    @channel.reload
    Whatsapp::ProviderConfigPresenter.new(@channel).perform['phone_registration']
  end

  def preserve_registration_state?(registration)
    return false if registration.blank?
    return true unless registration['status'] == 'registered'

    completed_at = Time.zone.parse(registration['completed_at'].to_s)
    completed_at > Time.current - Whatsapp::PhoneRegistrationService::HEALTH_RECONCILIATION_GRACE
  rescue ArgumentError
    false
  end

  def channel_in_pending_state?(health_data)
    health_data[:platform_type] == 'NOT_APPLICABLE' ||
      health_data.dig(:throughput, 'level') == 'NOT_APPLICABLE'
  end

  def channel_in_active_state?(health_data)
    throughput = health_data.dig(:throughput, 'level')
    health_data[:platform_type] == 'CLOUD_API' && throughput.present? && throughput != 'NOT_APPLICABLE'
  end
end
