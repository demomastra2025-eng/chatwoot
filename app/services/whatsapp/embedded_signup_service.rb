# This service coordinates the ordered OAuth, asset proof, token checks, and callback.
class Whatsapp::EmbeddedSignupService # rubocop:disable Metrics/ClassLength
  VALID_SIGNUP_TYPES = %w[standard coexistence].freeze

  class ReauthorizationFlowMismatchError < ArgumentError; end
  class ReauthorizationFlowRequiredError < ArgumentError; end

  include Whatsapp::EmbeddedSignupTokenWabaResolution

  # resolve_waba_from_token: the browser delivered only the auth code (mobile popup
  # lost Meta's session event), so the shared WABA is read from the token's scopes.
  def initialize(account:, params:, inbox_id: nil, resolve_waba_from_token: false)
    @account = account
    @code = params[:code]
    @requested_business_id = params[:business_id].presence
    @requested_waba_id = params[:waba_id].presence
    @requested_phone_number_id = params[:phone_number_id].presence
    @business_id = @requested_business_id
    @waba_id = @requested_waba_id
    @phone_number_id = @requested_phone_number_id
    @signup_type = params[:signup_type].presence
    @inbox_id = inbox_id
    @resolve_waba_from_token = resolve_waba_from_token && inbox_id.blank? && @waba_id.blank?
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
  def perform
    resolve_reauthorization_context!
    @signup_type ||= 'standard'
    validate_parameters!

    access_token = exchange_code_for_token
    resolve_waba_from_token!(access_token)
    resolve_reauthorization_identity!(access_token)
    phone_info = fetch_phone_info(access_token)
    @phone_number_id = phone_info[:phone_number_id]
    validate_coexistence_phone!(phone_info) if coexistence?
    token_health = validate_token_access(access_token)

    channel = create_or_reauthorize_channel_with_webhooks(access_token, phone_info, token_health)
    check_channel_health_and_prompt_reauth(channel) if @inbox_id.blank?
    if coexistence? && enqueue_coexistence_sync?(channel)
      generation = channel.provider_config.dig('coexistence_sync', 'generation')
      Whatsapp::CoexistenceSyncJob.perform_later(channel.id, generation) if generation.present?
    end
    channel

  rescue StandardError => e
    Rails.logger.error("[WHATSAPP] Embedded signup failed: #{safe_error_message(e)}")
    raise
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

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
    return unless token_health.present? && channel.respond_to?(:store_token_health!)

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
      rescue Whatsapp::PhoneRegistrationService::Error
        @phone_registration_incomplete = true
      rescue StandardError => e
        cleanup_failed_initial_channel(channel, teardown_webhook: !clean_callback_setup_failure?(e)) unless webhook_recovery_anchor_required?(e)
        raise
      end
      channel
    end
  end

  def reauthorize_channel_with_webhooks(access_token, phone_info, token_health)
    create_or_reauthorize_channel(access_token, phone_info) do |channel|
      channel.ensure_reauthorization_required_for_callback! if channel.respond_to?(:ensure_reauthorization_required_for_callback!)
      store_token_health(channel, token_health)
      authorization_snapshot = channel.reauthorization_callback_snapshot
      setup_webhooks!(channel)
      unless channel.complete_reauthorization_after_callback!(authorization_snapshot)
        raise Whatsapp::ReauthorizationService::CallbackAuthorizationStateChangedError
      end

      inbox = channel.inbox if channel.respond_to?(:inbox)
      inbox.resolve_failed_whatsapp_deletion_recovery! if inbox.respond_to?(:resolve_failed_whatsapp_deletion_recovery!)
      inbox&.update_account_cache
    end
  end

  def setup_webhooks!(channel)
    return Whatsapp::WebhookSetupService.new(channel).register_callback if @inbox_id.present?

    result = channel.setup_webhooks(strict: true, force_registration: !coexistence?)
    @phone_registration_completed = result == true unless coexistence?
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
      options[:identity_resolution] = @reauthorization_identity_resolution if @reauthorization_identity_resolution&.identity_changed?
      Whatsapp::ReauthorizationService.new(**options).perform(access_token, phone_info, &)
    else
      waba_info = { waba_id: @waba_id, business_id: @business_id, business_name: phone_info[:business_name] }
      return Whatsapp::ChannelCreationService.new(@account, waba_info, phone_info, access_token).perform unless coexistence?

      Whatsapp::ChannelCreationService.new(@account, waba_info, phone_info, access_token, signup_type: @signup_type).perform
    end
  end

  def check_channel_health_and_prompt_reauth(channel)
    return if @phone_registration_incomplete || @phone_registration_completed

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

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def resolve_reauthorization_context!
    return if @inbox_id.blank?

    inbox = @account.inboxes.find(@inbox_id)
    raise ActiveRecord::RecordNotFound if inbox.deleting_at.present?

    channel = inbox.channel
    config = channel.provider_config.to_h
    flows = [config['embedded_signup_flow'], @signup_type].compact_blank.uniq
    raise ReauthorizationFlowMismatchError, 'WhatsApp reauthorization flow does not match the existing channel' if flows.many?
    raise ReauthorizationFlowRequiredError, 'Select the existing WhatsApp connection type before reconnecting' if flows.empty?

    @signup_type = flows.first
    @reauthorization_snapshot = {
      account_id: @account.id,
      inbox_id: inbox.id,
      channel_id: channel.id,
      phone_number: channel.phone_number,
      identity: Whatsapp::ReauthorizationIdentityResolver::Resolution::IDENTITY_KEYS.index_with do |key|
        config[key].presence&.to_s
      end
    }
    if config['business_id'].present? && @requested_business_id.present? &&
       config['business_id'].to_s != @requested_business_id.to_s
      raise Whatsapp::ReauthorizationService::IdentityMismatchError,
            'WhatsApp reauthorization identity does not match the existing channel'
    end

    @reauthorization_identity_resolution_required =
      (@requested_waba_id.blank? && @requested_phone_number_id.blank?) ||
      (@requested_waba_id.present? && @requested_waba_id.to_s != config['business_account_id'].to_s) ||
      (@requested_phone_number_id.present? && @requested_phone_number_id.to_s != config['phone_number_id'].to_s)
    if @reauthorization_identity_resolution_required
      @waba_id = @requested_waba_id
      @phone_number_id = @requested_phone_number_id
      @business_id = @requested_business_id
    else
      @phone_number_id = Whatsapp::ReauthorizationService.resolve_identifier(config['phone_number_id'], @requested_phone_number_id)
      @business_id = Whatsapp::ReauthorizationService.resolve_identifier(config['business_id'], @requested_business_id)
      @waba_id = Whatsapp::ReauthorizationService.resolve_identifier(config['business_account_id'], @requested_waba_id)
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def resolve_reauthorization_identity!(access_token)
    return unless @reauthorization_identity_resolution_required

    snapshot = @reauthorization_snapshot
    if @requested_waba_id.blank? && @requested_phone_number_id.blank?
      begin
        # Prefer the stored identity when the fresh token still proves that exact pair.
        # This preserves legacy code-only reconnects that have no owner_business_id.
        @reauthorization_identity_resolution = build_reauthorization_identity_resolver(
          access_token,
          snapshot,
          requested_waba_id: snapshot[:identity]['business_account_id'],
          requested_phone_number_id: snapshot[:identity]['phone_number_id']
        ).perform
        assign_reauthorization_identity!
        return
      rescue Whatsapp::ReauthorizationIdentityResolver::ResolutionError => e
        if e.error_code == 'grant_targets_unavailable' &&
           snapshot[:identity]['business_account_id'].present? &&
           snapshot[:identity]['phone_number_id'].present?
          # No granular target list: retain the legacy exact-ID path, which still
          # validates the fresh token against the persisted WABA and phone below.
          @waba_id = snapshot[:identity]['business_account_id']
          @phone_number_id = snapshot[:identity]['phone_number_id']
          @business_id = snapshot[:identity]['business_id']
          return
        end

        raise unless %w[business_asset_selection_mismatch asset_not_found phone_asset_selection_mismatch].include?(e.error_code)
      end
    end

    @reauthorization_identity_resolution = build_reauthorization_identity_resolver(
      access_token,
      snapshot,
      requested_waba_id: @requested_waba_id,
      requested_phone_number_id: @requested_phone_number_id
    ).perform
    assign_reauthorization_identity!
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def build_reauthorization_identity_resolver(access_token, snapshot, requested_waba_id:, requested_phone_number_id:)
    Whatsapp::ReauthorizationIdentityResolver.new(
      access_token: access_token,
      account_id: snapshot[:account_id],
      inbox_id: snapshot[:inbox_id],
      channel_id: snapshot[:channel_id],
      old_identity: snapshot[:identity],
      phone_number: snapshot[:phone_number],
      signup_type: @signup_type,
      requested_waba_id: requested_waba_id,
      requested_phone_number_id: requested_phone_number_id,
      requested_business_id: @requested_business_id
    )
  end

  def assign_reauthorization_identity!
    @waba_id = @reauthorization_identity_resolution.target_identity['business_account_id']
    @phone_number_id = @reauthorization_identity_resolution.target_identity['phone_number_id']
    @business_id = @reauthorization_identity_resolution.target_identity['business_id']
  end

  def enqueue_coexistence_sync?(channel)
    return false if @reauthorization_identity_resolution&.identity_changed?

    sync = channel.provider_config.to_h['coexistence_sync'].to_h
    !Whatsapp::CoexistenceSyncService.terminal_state?(sync)
  end

  def coexistence?
    @signup_type == 'coexistence'
  end

  def validate_coexistence_phone!(phone_info)
    return if phone_info[:is_on_biz_app] && phone_info[:platform_type] == 'CLOUD_API'

    raise 'Selected number is not connected to both WhatsApp Business app and Cloud API'
  end
end
