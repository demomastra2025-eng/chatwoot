# The setup service coordinates an intentionally broad provider transaction.
# rubocop:disable Metrics/ClassLength
class Whatsapp::WebhookSetupService
  class CallbackSetupError < RuntimeError; end
  class StaleRecoveryIdentityError < RuntimeError; end
  class StalePhoneRegistrationIdentityError < RuntimeError; end
  class PostMutationRecoveryError < Whatsapp::FacebookApiClient::WebhookRecoveryAnchorRequiredError; end

  CALLBACK_RECOVERY_KEY = Whatsapp::WebhookCallbackRecoveryService::CONFIG_KEY
  CALLBACK_RECOVERY_ACTIVE_STATES = Whatsapp::WebhookCallbackRecoveryService::ACTIVE_STATES

  # Positional arguments are retained for the existing setup callers.
  # rubocop:disable Metrics/ParameterLists
  def initialize(channel, waba_id = nil, access_token = nil, strict: false, force_registration: false, recovery_generation: nil,
                 expected_credential_fingerprint: nil)
    @channel = channel
    @waba_id = waba_id || channel.provider_config['business_account_id']
    @access_token = access_token || channel.provider_config['api_key']
    @phone_number_id = channel&.provider_config&.[]('phone_number_id')
    @api_client = Whatsapp::FacebookApiClient.new(@access_token)
    @strict = strict
    @force_registration = force_registration
    @recovery_generation = recovery_generation
    @expected_credential_fingerprint = expected_credential_fingerprint
  end
  # rubocop:enable Metrics/ParameterLists

  def perform
    validate_parameters!

    with_waba_lock do
      setup_webhook
      register_phone_number if register_phone_number?
    end
  end

  def register_callback(schedule_recovery: true)
    validate_parameters!
    with_waba_lock { setup_webhook(schedule_recovery: schedule_recovery) }
  end

  def register_callback_if_missing
    validate_parameters!
    with_waba_lock do
      validate_expected_credentials!
      next :healthy if @api_client.app_subscribed_to_waba?(@waba_id)

      setup_webhook
      :repaired
    end
  end

  def register_phone_number_with_pin!(pin)
    validate_parameters!
    with_waba_lock do
      validate_phone_registration_identity!
      phone_registration_service.perform(pin: pin)
    end
  end

  def require_manual_callback_recovery!(error)
    changed = callback_recovery.manual_recovery_required!(error)
    @channel.prompt_reauthorization! if changed
  end

  private

  def with_waba_lock(&)
    Whatsapp::WabaLock.new(@waba_id).with_lock(&)
  end

  def validate_parameters!
    raise ArgumentError, 'Channel is required' if @channel.blank?
    raise ArgumentError, 'WABA ID is required' if @waba_id.blank?
    raise ArgumentError, 'Access token is required' if @access_token.blank?
  end

  def register_phone_number
    validate_phone_registration_identity!
    return if phone_registration_service.automatic_retry_blocked?

    pin = fetch_or_create_pin
    phone_registration_service.perform(pin: pin)
  rescue StandardError => e
    safe_message = sanitized_error_message(e)
    Rails.logger.warn("[WHATSAPP] Phone registration failed#{@strict ? '' : ' but continuing'}: #{safe_message}")
    raise if @strict
  end

  def fetch_or_create_pin
    # Check if we have a stored PIN for this phone number
    existing_pin = @channel.provider_config['verification_pin']
    return existing_pin.to_s if existing_pin.present?

    # Generate a new 6-digit PIN if none exists
    (SecureRandom.random_number(900_000) + 100_000).to_s
  end

  def phone_registration_service
    @phone_registration_service ||= Whatsapp::PhoneRegistrationService.new(
      @channel,
      api_client: @api_client,
      phone_number_id: @phone_number_id
    )
  end

  def validate_phone_registration_identity!
    config = @channel.reload.provider_config.to_h
    current_identity = [config['business_account_id'], config['api_key'], config['phone_number_id']].map(&:to_s)
    expected_identity = [@waba_id, @access_token, @phone_number_id].map(&:to_s)
    return if current_identity == expected_identity

    raise StalePhoneRegistrationIdentityError, 'WhatsApp phone registration identity changed'
  end

  # Recovery writes intentionally stay adjacent to the remote callback mutation.
  def setup_webhook(schedule_recovery: true)
    remote_callback_updated = false
    recovery_target = nil
    validate_expected_credentials!
    validate_waba_ownership!
    validate_recovery_identity!
    callback_url, verify_token, recovery_target = callback_details

    callback_recovery.updating!(**recovery_target)
    subscribe_waba_callback(callback_url, verify_token)
    remote_callback_updated = true
    callback_recovery.resolved!(**recovery_target)

  rescue Whatsapp::FacebookApiClient::WebhookRecoveryAnchorRequiredError => e
    preserve_callback_recovery!(recovery_target, e, schedule_recovery: schedule_recovery)
    Rails.logger.error("[WHATSAPP] Webhook setup failed: #{sanitized_error_message(e)}")
    raise
  rescue StaleRecoveryIdentityError
    raise
  rescue StandardError => e
    handle_setup_error!(recovery_target, e, remote_callback_updated, schedule_recovery)
  end

  def handle_setup_error!(recovery_target, error, remote_callback_updated, schedule_recovery)
    raise_post_mutation_recovery_error!(recovery_target, error, schedule_recovery: schedule_recovery) if remote_callback_updated

    raise_callback_setup_error!(recovery_target, error)
  end

  def raise_post_mutation_recovery_error!(recovery_target, cause, schedule_recovery:)
    recovery_error = PostMutationRecoveryError.new(
      'Webhook callback was updated but the local recovery state could not be finalized'
    )
    preserve_callback_recovery!(recovery_target, recovery_error, schedule_recovery: schedule_recovery)
    Rails.logger.error("[WHATSAPP] Webhook callback recovery finalization failed: #{sanitized_error_message(cause)}")
    raise recovery_error
  end

  def raise_callback_setup_error!(recovery_target, error)
    callback_recovery.failed!(**recovery_target, error: error) if recovery_target.present?
    safe_message = sanitized_error_message(error)
    Rails.logger.error("[WHATSAPP] Webhook setup failed: #{safe_message}")
    raise CallbackSetupError, "Webhook setup failed: #{safe_message}"
  end

  def preserve_callback_recovery!(recovery_target, error, schedule_recovery:)
    callback_recovery.outcome_unknown!(**recovery_target, error: error)
  rescue StandardError => e
    Rails.logger.error("[WHATSAPP] Failed to persist callback recovery state: #{sanitized_error_message(e)}")
  ensure
    schedule_callback_reconciliation if schedule_recovery
  end

  def schedule_callback_reconciliation
    generation = callback_recovery.generation
    Whatsapp::WebhookCallbackReconciliationJob.perform_later(@channel.id, @waba_id, generation)
  rescue StandardError => e
    Rails.logger.error("[WHATSAPP] Failed to schedule callback reconciliation: #{sanitized_error_message(e)}")
  end

  def callback_details
    callback_url = build_callback_url
    verify_token = callback_verify_token
    [callback_url, verify_token, callback_recovery_target(callback_url, verify_token)]
  end

  def build_callback_url
    @channel.callback_webhook_url
  end

  def callback_verify_token
    return global_verify_token unless @channel.manual_webhook_callback?

    @channel.provider_config['webhook_verify_token'].presence ||
      raise(ArgumentError, 'Channel WhatsApp webhook verify token is required')
  end

  def global_verify_token
    GlobalConfigService.load('WHATSAPP_WEBHOOK_VERIFY_TOKEN', nil).presence ||
      raise(ArgumentError, 'Global WhatsApp webhook verify token is required')
  end

  def subscribe_waba_callback(callback_url, verify_token)
    return @api_client.subscribe_waba_webhook(@waba_id, callback_url, verify_token) unless coexistence_subscription_required?

    @api_client.subscribe_waba_webhook(
      @waba_id,
      callback_url,
      verify_token,
      subscribed_fields: webhook_subscribed_fields
    )
  end

  def webhook_subscribed_fields
    return Whatsapp::FacebookApiClient::WEBHOOK_DEFAULT_FIELDS unless coexistence_subscription_required?

    @api_client.webhook_subscribed_fields(coexistence: true)
  end

  def callback_recovery_target(callback_url, verify_token)
    { callback_url: callback_url, verify_token: verify_token, subscribed_fields: webhook_subscribed_fields }
  end

  def callback_recovery
    @callback_recovery ||= Whatsapp::WebhookCallbackRecoveryService.new(
      @channel,
      @waba_id,
      secrets: [@access_token],
      generation: @recovery_generation
    )
  end

  def validate_recovery_identity!
    return if @recovery_generation.blank?

    config = @channel.reload.provider_config.to_h
    recovery = config[CALLBACK_RECOVERY_KEY].to_h
    return if config['business_account_id'].to_s == @waba_id.to_s && recovery['waba_id'].to_s == @waba_id.to_s &&
              recovery['generation'].to_s == @recovery_generation.to_s

    raise StaleRecoveryIdentityError, 'Webhook callback recovery identity is stale'
  end

  def validate_expected_credentials!
    return if @expected_credential_fingerprint.blank?

    @channel.reload
    return if active_callback_channel? && current_credential_fingerprint == @expected_credential_fingerprint

    raise StaleRecoveryIdentityError, 'Webhook subscription health identity is stale'
  end

  def active_callback_channel?
    @channel.provider == 'whatsapp_cloud' && @channel.account.active? &&
      @channel.inbox.present? && @channel.inbox.deleting_at.nil?
  end

  def current_credential_fingerprint
    config = @channel.provider_config.to_h
    Digest::SHA256.hexdigest([config['business_account_id'], config['api_key']].map(&:to_s).join("\0"))
  end

  def channel_coexistence?
    @channel.provider_config.to_h['embedded_signup_flow'] == 'coexistence'
  end

  def coexistence_subscription_required?
    return true if channel_coexistence?

    Channel::Whatsapp.lifecycle_cloud
                     .where.not(id: @channel.id)
                     .for_waba(@waba_id)
                     .where("provider_config ->> 'embedded_signup_flow' = 'coexistence'")
                     .exists?
  end

  def validate_waba_ownership!
    account_ids = Channel::Whatsapp.lifecycle_cloud.for_waba(@waba_id)
                                   .distinct
                                   .limit(2)
                                   .pluck(:account_id)
    return if account_ids.empty? || (account_ids.one? && account_ids.first == @channel.account_id)

    raise 'Webhook setup refused because WABA ownership spans multiple accounts'
  end

  def register_phone_number?
    return false if channel_coexistence?
    return true if @force_registration

    !phone_number_verified? || phone_number_needs_registration?
  end

  def phone_number_verified?
    phone_number_id = @channel.provider_config['phone_number_id']

    # Check with WhatsApp API if the phone number code verification is complete
    # This checks code_verification_status == 'VERIFIED'
    verified = @api_client.phone_number_verified?(phone_number_id)
    Rails.logger.info("[WHATSAPP] Phone number #{phone_number_id} code verification status: #{verified}")

    verified
  rescue StandardError => e
    # If verification check fails, assume not verified to be safe
    Rails.logger.error("[WHATSAPP] Phone verification status check failed: #{sanitized_error_message(e)}")
    false
  end

  def phone_number_needs_registration?
    # Check if phone is in pending provisioning state based on health data
    # This is a separate check from phone_number_verified? which only checks code verification

    phone_number_in_pending_state?

  rescue StandardError => e
    Rails.logger.error("[WHATSAPP] Phone registration check failed: #{sanitized_error_message(e)}")
    # Conservative approach: don't register if we can't determine the state
    false
  end

  def phone_number_in_pending_state?
    health_service = Whatsapp::HealthService.new(@channel)
    health_data = health_service.fetch_health_status

    # Check if phone number is in "not provisioned" state based on health indicators
    # These conditions indicate the number is pending and needs registration:
    # - platform_type: "NOT_APPLICABLE" means not fully set up
    # - throughput.level: "NOT_APPLICABLE" means no messaging capacity assigned
    health_data[:platform_type] == 'NOT_APPLICABLE' ||
      health_data.dig(:throughput, 'level') == 'NOT_APPLICABLE' ||
      health_data.dig(:throughput, :level) == 'NOT_APPLICABLE'

  rescue StandardError => e
    Rails.logger.error("[WHATSAPP] Health status check failed: #{sanitized_error_message(e)}")
    # If health check fails, assume registration is not needed to avoid errors
    false
  end

  def sanitized_error_message(error)
    secrets = [@access_token, *Meta::CredentialDataSanitizer.channel_secrets(@channel)].compact_blank
    Meta::CredentialDataSanitizer.sanitize(error.message.to_s.first(5000), secrets: secrets)
  end
end
# rubocop:enable Metrics/ClassLength
