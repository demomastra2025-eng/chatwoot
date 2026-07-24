module Api::V1::Accounts::Concerns::WhatsappHealthManagement
  extend ActiveSupport::Concern

  included do
    skip_before_action :check_authorization, only: [:health, :register_webhook]
    before_action :check_admin_authorization?, only: [:register_webhook]
    before_action :validate_whatsapp_cloud_channel, only: [:health, :register_webhook]
  end

  def sync_templates
    return render status: :unprocessable_entity, json: { error: 'Template sync is only available for WhatsApp channels' } unless whatsapp_channel?

    sync_result = trigger_template_sync
    unless sync_result
      return render status: :unprocessable_entity, json: { error: 'Template sync failed. Please check provider configuration and try again.' }
    end

    @inbox.reload
    render 'api/v1/accounts/inboxes/show', status: :ok
  rescue StandardError => e
    log_whatsapp_operation_error('TEMPLATE SYNC', e)
    render status: :internal_server_error,
           json: { error: 'Template sync failed. Please check provider configuration and try again.' }
  end

  def health
    health_data = Whatsapp::HealthService.new(@inbox.channel).fetch_health_status
    render json: health_data
  rescue StandardError => e
    log_whatsapp_operation_error('HEALTH', e)
    render json: { error: 'Unable to fetch WhatsApp health data. Please try again.' }, status: :unprocessable_entity
  end

  def register_webhook
    Whatsapp::WebhookSetupService.new(@inbox.channel).register_callback

    render json: { message: 'Webhook registered successfully' }, status: :ok
  rescue StandardError => e
    log_whatsapp_operation_error('WEBHOOK', e)
    render json: { error: 'Webhook registration failed. Please try again.' }, status: :unprocessable_entity
  end

  private

  def log_whatsapp_operation_error(operation, error)
    secrets = Meta::CredentialDataSanitizer.channel_secrets(@inbox&.channel)
    safe_message = Meta::CredentialDataSanitizer.sanitize(error.message.to_s.first(1000), secrets: secrets)
    Rails.logger.error "[INBOX #{operation}] WhatsApp operation failed: #{safe_message}"
  end

  def validate_whatsapp_cloud_channel
    return if @inbox.channel.is_a?(Channel::Whatsapp) && @inbox.channel.provider == 'whatsapp_cloud'

    render json: { error: 'Health data only available for WhatsApp Cloud API channels' }, status: :bad_request
  end

  def whatsapp_channel?
    @inbox.whatsapp? || (@inbox.twilio? && @inbox.channel.whatsapp?)
  end

  def trigger_template_sync
    if @inbox.whatsapp?
      @inbox.channel.sync_templates
    elsif @inbox.twilio? && @inbox.channel.whatsapp?
      Twilio::TemplateSyncService.new(channel: @inbox.channel).call
    end
  end
end
