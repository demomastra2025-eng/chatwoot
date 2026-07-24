class Whatsapp::EmbeddedSignupService
  VALID_SIGNUP_TYPES = %w[standard coexistence].freeze

  class ReauthorizationFlowMismatchError < ArgumentError; end
  class ReauthorizationFlowRequiredError < ArgumentError; end

  def initialize(account:, params:, inbox_id: nil)
    @account = account
    @code = params[:code]
    @business_id = params[:business_id].presence
    @waba_id = params[:waba_id]
    @phone_number_id = params[:phone_number_id].presence
    @signup_type = params[:signup_type].presence
    @inbox_id = inbox_id
  end

  def perform
    resolve_reauthorization_context!
    @signup_type ||= 'standard'
    validate_parameters!

    access_token = exchange_code_for_token
    phone_info = fetch_phone_info(access_token)
    @phone_number_id = phone_info[:phone_number_id]
    validate_coexistence_phone!(phone_info) if coexistence?
    token_health = validate_token_access(access_token)

    channel = create_or_reauthorize_channel_with_webhooks(access_token, phone_info, token_health)
    # Skip health check during reauthorization — phone numbers in pending provisioning state
    # (platform_type: NOT_APPLICABLE) would incorrectly trigger a disconnect email right after
    # a successful reauth. Only run health check for new channel creation.
    check_channel_health_and_prompt_reauth(channel) if @inbox_id.blank?
    if coexistence?
      generation = channel.provider_config.dig('coexistence_sync', 'generation')
      Whatsapp::CoexistenceSyncJob.perform_later(channel.id, generation)
    end
    channel

  rescue StandardError => e
    Rails.logger.error("[WHATSAPP] Embedded signup failed: #{safe_error_message(e)}")
    raise
  end

  private

  def exchange_code_for_token
    Whatsapp::TokenExchangeService.new(@code).perform
  end

  def fetch_phone_info(access_token)
    options = {}
    options[:coexistence] = true if coexistence?
    options[:allow_unambiguous_selection] = true if @phone_number_id.blank? && !coexistence?
    Whatsapp::PhoneInfoService.new(@waba_id, @phone_number_id, access_token, **options).perform
  end

  def validate_token_access(access_token)
    Whatsapp::TokenValidationService.new(
      access_token,
      @waba_id,
      phone_number_id: @phone_number_id,
      require_non_expiring_system_user: require_non_expiring_system_user_token?
    ).perform
  end

  def store_token_health(channel, token_health)
    return if token_health.blank?
    return unless channel.respond_to?(:store_token_health!)

    channel.store_token_health!(token_health)
  end

  def create_or_reauthorize_channel_with_webhooks(access_token, phone_info, token_health)
    return reauthorize_channel_with_webhooks(access_token, phone_info, token_health) if @inbox_id.present?

    Whatsapp::WabaLock.new(@waba_id).with_lock do
      channel = nil
      begin
        channel = create_or_reauthorize_channel(access_token, phone_info)
        store_token_health(channel, token_health)
        setup_webhooks!(channel)
        channel
      rescue StandardError => e
        cleanup_failed_initial_channel(channel, teardown_webhook: !clean_callback_setup_failure?(e)) unless webhook_recovery_anchor_required?(e)
        raise
      end
    end
  end

  def reauthorize_channel_with_webhooks(access_token, phone_info, token_health)
    create_or_reauthorize_channel(access_token, phone_info) do |channel|
      store_token_health(channel, token_health)
      setup_webhooks!(channel)
      mark_channel_reauthorized(channel)
    end
  end

  def mark_channel_reauthorized(channel)
    channel.reauthorized! if channel.respond_to?(:reauthorized!)
  end

  def setup_webhooks!(channel)
    # NOTE: We call setup_webhooks explicitly here instead of relying on after_commit callback because:
    # 1. Reauthorization flow updates an existing channel (not a create), so after_commit on: :create won't trigger
    # 2. We need to run check_channel_health_and_prompt_reauth after webhook setup completes
    # 3. The channel is marked with source: 'embedded_signup' to skip the after_commit callback
    # For initial signup, this must run after the channel transaction commits; Meta verifies
    # the callback URL immediately and the public verifier reads the channel token from DB.
    channel.setup_webhooks(strict: true, force_registration: @inbox_id.blank? && !coexistence?)
  end

  def cleanup_failed_initial_channel(channel, teardown_webhook: true)
    return if channel.blank?

    inbox = channel.inbox
    unless teardown_webhook
      channel.skip_webhook_teardown = true
      channel.destroy!
    end
    inbox&.destroy!
  rescue StandardError => e
    Rails.logger.error("[WHATSAPP] Failed to cleanup channel after embedded signup error: #{safe_error_message(e, channel: channel)}")
  end

  def webhook_recovery_anchor_required?(error)
    error.is_a?(Whatsapp::FacebookApiClient::WebhookRecoveryAnchorRequiredError)
  end

  def clean_callback_setup_failure?(error)
    error.is_a?(Whatsapp::WebhookSetupService::CallbackSetupError)
  end

  def create_or_reauthorize_channel(access_token, phone_info, &)
    if @inbox_id.present?
      options = {
        account: @account,
        inbox_id: @inbox_id,
        phone_number_id: @phone_number_id,
        business_id: @business_id,
        waba_id: @waba_id
      }
      options[:signup_type] = @signup_type
      Whatsapp::ReauthorizationService.new(**options).perform(access_token, phone_info, &)
    else
      waba_info = { waba_id: @waba_id, business_id: @business_id, business_name: phone_info[:business_name] }
      return Whatsapp::ChannelCreationService.new(@account, waba_info, phone_info, access_token).perform unless coexistence?

      Whatsapp::ChannelCreationService.new(@account, waba_info, phone_info, access_token, signup_type: @signup_type).perform
    end
  end

  def check_channel_health_and_prompt_reauth(channel)
    health_data = Whatsapp::HealthService.new(channel).fetch_health_status
    return unless health_data

    if channel_in_pending_state?(health_data)
      channel.prompt_reauthorization!
    else
      Rails.logger.info "[WHATSAPP] Channel #{channel.phone_number} health check passed"
    end
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP] Health check failed for channel #{channel.phone_number}: #{safe_error_message(e, channel: channel)}"
  end

  def safe_error_message(error, channel: nil)
    app_id = GlobalConfigService.load('WHATSAPP_APP_ID', '')
    app_secret = GlobalConfigService.load('WHATSAPP_APP_SECRET', '')
    secrets = [@code, app_secret, "#{app_id}|#{app_secret}"]
    secrets.concat(Meta::CredentialDataSanitizer.channel_secrets(channel)) if channel
    Meta::CredentialDataSanitizer.sanitize(error.message.to_s.first(500), secrets: secrets)
  end

  def channel_in_pending_state?(health_data)
    health_data[:platform_type] == 'NOT_APPLICABLE' ||
      health_data.dig(:throughput, 'level') == 'NOT_APPLICABLE'
  end

  def require_non_expiring_system_user_token?
    ActiveModel::Type::Boolean.new.cast(
      GlobalConfigService.load('WHATSAPP_REQUIRE_NON_EXPIRING_SYSTEM_USER_TOKEN', false)
    )
  end

  def validate_parameters!
    raise ArgumentError, 'Unsupported WhatsApp Embedded Signup type' unless VALID_SIGNUP_TYPES.include?(@signup_type)

    missing_params = required_signup_parameters.filter_map do |name|
      name.to_s if instance_variable_get("@#{name}").blank?
    end

    return if missing_params.empty?

    raise ArgumentError, "Required parameters are missing: #{missing_params.join(', ')}"
  end

  def required_signup_parameters
    %i[code waba_id]
  end

  def resolve_reauthorization_context!
    return if @inbox_id.blank?

    channel = @account.inboxes.find(@inbox_id).channel
    config = channel.provider_config.to_h
    flows = [config['embedded_signup_flow'], @signup_type].compact_blank.uniq
    raise ReauthorizationFlowMismatchError, 'WhatsApp reauthorization flow does not match the existing channel' if flows.many?
    raise ReauthorizationFlowRequiredError, 'Select the existing WhatsApp connection type before reconnecting' if flows.empty?

    @signup_type = flows.first
    @phone_number_id = Whatsapp::ReauthorizationService.resolve_identifier(config['phone_number_id'], @phone_number_id)
    @business_id = Whatsapp::ReauthorizationService.resolve_identifier(config['business_id'], @business_id)
    @waba_id = Whatsapp::ReauthorizationService.resolve_identifier(config['business_account_id'], @waba_id)
  end

  def coexistence?
    @signup_type == 'coexistence'
  end

  def validate_coexistence_phone!(phone_info)
    return if phone_info[:is_on_biz_app] && phone_info[:platform_type] == 'CLOUD_API'

    raise 'Selected number is not connected to both WhatsApp Business app and Cloud API'
  end
end
