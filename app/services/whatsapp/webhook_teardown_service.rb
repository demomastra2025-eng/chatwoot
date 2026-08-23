class Whatsapp::WebhookTeardownService
  class WebhookHandoffError < StandardError; end
  class WebhookTeardownError < StandardError; end

  def initialize(channel)
    @channel = channel
  end

  def perform
    return unless should_teardown_webhook?

    teardown_webhook
  rescue WebhookHandoffError
    raise
  rescue StandardError => e
    handle_webhook_teardown_error(e)
    raise WebhookTeardownError, 'WhatsApp webhook teardown failed'
  end

  private

  def should_teardown_webhook?
    whatsapp_cloud_provider? && embedded_signup_source? && webhook_config_present?
  end

  def whatsapp_cloud_provider?
    @channel.provider == 'whatsapp_cloud'
  end

  def embedded_signup_source?
    @channel.provider_config['source'] == 'embedded_signup'
  end

  def webhook_config_present?
    @channel.provider_config['business_account_id'].present? &&
      @channel.provider_config['api_key'].present?
  end

  def teardown_webhook
    waba_id = @channel.provider_config['business_account_id']
    with_waba_lock(waba_id) do
      next unregister_remote_route!(waba_id) if route_registry_client.configured?

      teardown_local_subscription!(waba_id)
    end
  end

  def unregister_remote_route!(waba_id)
    route_registry_client.unregister!(
      waba_id: waba_id,
      phone_number_id: @channel.provider_config['phone_number_id']
    )
    Rails.logger.info "[WHATSAPP] Remote webhook route removed for channel #{@channel.id}"
  end

  def teardown_local_subscription!(waba_id)
    refuse_cross_account_handoff!(waba_id) if cross_account_sibling_exists?(waba_id)
    sibling = sibling_waba_channel(waba_id)
    return handoff_to_sibling!(sibling, waba_id) if sibling.present?

    refuse_pending_sibling_teardown! if pending_deletion_sibling_exists?(waba_id)
    unsubscribe_waba!(waba_id)
  end

  def refuse_cross_account_handoff!(waba_id)
    Rails.logger.error '[WHATSAPP] Webhook teardown refused because WABA ownership spans multiple accounts'
    raise WebhookHandoffError, "WhatsApp webhook teardown refused because WABA #{waba_id} ownership is ambiguous"
  end

  def refuse_pending_sibling_teardown!
    Rails.logger.error '[WHATSAPP] Webhook teardown deferred because a WABA sibling is pending deletion'
    raise WebhookHandoffError, 'WhatsApp webhook teardown refused while a sibling is pending deletion'
  end

  def unsubscribe_waba!(waba_id)
    access_token = @channel.provider_config['api_key']
    Whatsapp::FacebookApiClient.new(access_token).unsubscribe_waba_webhook(waba_id)
    Rails.logger.info "[WHATSAPP] Webhook unsubscribed successfully for channel #{@channel.id}"
  end

  def handoff_to_sibling!(sibling, waba_id)
    Whatsapp::WebhookSetupService.new(sibling).register_callback
    Rails.logger.info "[WHATSAPP] Webhook moved to sibling channel #{sibling.id} for WABA #{waba_id}"
  rescue StandardError => e
    handle_webhook_teardown_error(e)
    raise WebhookHandoffError, 'WhatsApp webhook callback handoff failed'
  end

  def sibling_waba_channel(waba_id)
    Channel::Whatsapp.active_cloud
                     .where(account_id: @channel.account_id)
                     .where.not(id: @channel.id)
                     .for_waba(waba_id)
                     .first
  end

  def cross_account_sibling_exists?(waba_id)
    Channel::Whatsapp.lifecycle_cloud
                     .where.not(account_id: @channel.account_id)
                     .for_waba(waba_id)
                     .exists?
  end

  def pending_deletion_sibling_exists?(waba_id)
    Channel::Whatsapp.lifecycle_cloud
                     .joins(:inbox)
                     .where(account_id: @channel.account_id)
                     .where.not(id: @channel.id)
                     .where.not(inboxes: { deleting_at: nil })
                     .for_waba(waba_id)
                     .exists?
  end

  def with_waba_lock(waba_id, &)
    Whatsapp::WabaLock.new(waba_id).with_lock(&)
  end

  def route_registry_client
    @route_registry_client ||= Whatsapp::WebhookRouteRegistryClient.new
  end

  def handle_webhook_teardown_error(error)
    safe_message = Meta::CredentialDataSanitizer.sanitize(
      error.message.to_s,
      secrets: Meta::CredentialDataSanitizer.channel_secrets(@channel)
    )
    Rails.logger.error "[WHATSAPP] Webhook teardown failed: #{safe_message}"
  end
end
