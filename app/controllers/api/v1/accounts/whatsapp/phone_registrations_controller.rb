class Api::V1::Accounts::Whatsapp::PhoneRegistrationsController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?
  before_action :fetch_channel

  def create
    Whatsapp::WebhookSetupService.new(@channel).register_phone_number_with_pin!(params[:verification_pin])
    @channel.reload

    render json: {
      success: true,
      inbox_id: @inbox.id,
      reauthorization_required: @channel.reauthorization_required?,
      provider_config: Whatsapp::ProviderConfigPresenter.new(@channel).perform
    }
  rescue Whatsapp::PhoneRegistrationService::Error => e
    render json: error_response(e), status: error_status(e)
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP PHONE REGISTRATION] #{safe_error_message(e)}"
    render json: { success: false, error_code: 'registration_failed' }, status: :unprocessable_content
  end

  private

  def fetch_channel
    @inbox = Current.account.inboxes.find(params.require(:inbox_id))
    @channel = @inbox.channel
    return if @channel.is_a?(Channel::Whatsapp) && @channel.provider == 'whatsapp_cloud' &&
              @channel.provider_config.to_h['embedded_signup_flow'] != 'coexistence' &&
              !hard_authorization_failure? && registration_required?

    render json: {
      success: false,
      error_code: invalid_registration_error_code
    }, status: :unprocessable_content
  end

  def registration_required?
    config = @channel.provider_config.to_h
    registration_status = config.dig(Whatsapp::PhoneRegistrationService::CONFIG_KEY, 'status')
    return false if registration_status == 'registered'

    registration_status.present?
  end

  def hard_authorization_failure?
    config = @channel.provider_config.to_h
    config['authorization_status'] == 'reauthorization_required' ||
      Whatsapp::TokenInspectionService::REAUTHORIZATION_STATUSES.include?(config.dig('token_health', 'status'))
  end

  def invalid_registration_error_code
    if @channel.is_a?(Channel::Whatsapp) && @channel.provider == 'whatsapp_cloud'
      return 'invalid_inbox_channel' if @channel.provider_config.to_h['embedded_signup_flow'] == 'coexistence'
      return 'reauthorization_required' if hard_authorization_failure?

      return 'registration_not_required'
    end

    'invalid_inbox_channel'
  end

  def error_response(error)
    {
      success: false,
      error_code: error.error_code,
      provider_error_code: error.provider_code,
      retry_after_at: error.retry_after_at&.iso8601,
      provider_config: Whatsapp::ProviderConfigPresenter.new(@channel.reload).perform
    }.compact
  end

  def error_status(error)
    return :too_many_requests if error.error_code == 'rate_limited'
    return :conflict if error.error_code == 'outcome_unknown'

    :unprocessable_content
  end

  def safe_error_message(error)
    Meta::CredentialDataSanitizer.sanitize(
      error.message.to_s.first(1000),
      secrets: [params[:verification_pin], *Meta::CredentialDataSanitizer.channel_secrets(@channel)].compact_blank
    )
  end
end
