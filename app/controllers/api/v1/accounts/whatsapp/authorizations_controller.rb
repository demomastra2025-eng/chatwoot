class Api::V1::Accounts::Whatsapp::AuthorizationsController < Api::V1::Accounts::BaseController
  AUTHORIZATION_ONLY_PROVIDER_CONFIG_KEYS = %w[calling_capabilities token_health].freeze

  class MissingRequiredParametersError < ArgumentError
    attr_reader :missing_parameters

    def initialize(missing_parameters)
      @missing_parameters = missing_parameters
      super("Required parameters are missing: #{missing_parameters.join(', ')}")
    end
  end

  before_action :check_admin_authorization?
  before_action :fetch_and_validate_inbox, if: -> { params[:inbox_id].present? }

  # POST /api/v1/accounts/:account_id/whatsapp/authorization
  # Handles both initial authorization and reauthorization
  # If inbox_id is present in params, it performs reauthorization
  def create
    validate_embedded_signup_params!
    channel = process_embedded_signup
    render_success_response(channel.inbox)
  rescue StandardError => e
    render_error_response(e)
  end

  def log_session
    payload = session_params.to_h.compact_blank.transform_values { |value| value.to_s.first(128) }
    return render json: { error: 'Missing Embedded Signup event' }, status: :unprocessable_content if payload['event'].blank?

    Rails.logger.info(
      {
        event: 'whatsapp_embedded_signup_session',
        account_id: Current.account.id,
        user_id: Current.user&.id,
        session: payload
      }.to_json
    )
    head :accepted
  end

  private

  def process_embedded_signup
    service = Whatsapp::EmbeddedSignupService.new(
      account: Current.account,
      params: params.permit(:code, :business_id, :waba_id, :phone_number_id, :signup_type).to_h.symbolize_keys,
      inbox_id: params[:inbox_id]
    )
    service.perform
  end

  def fetch_and_validate_inbox
    @inbox = Current.account.inboxes.find(params[:inbox_id])
    validate_whatsapp_cloud_inbox
    return if performed?

    validate_reauthorization_required
  end

  def validate_whatsapp_cloud_inbox
    return if @inbox.channel.is_a?(Channel::Whatsapp) && @inbox.channel.provider == 'whatsapp_cloud'

    render json: {
      success: false,
      error: 'WhatsApp Cloud inbox is required for embedded signup reauthorization',
      error_code: 'invalid_inbox_channel'
    }, status: :unprocessable_content
  end

  def validate_reauthorization_required
    return if @inbox.channel.reauthorization_required? || can_upgrade_to_embedded_signup? || token_expiring?

    render json: {
      success: false,
      message: I18n.t('inbox.reauthorization.not_required')
    }, status: :unprocessable_content
  end

  def token_expiring?
    token_health_status = @inbox.channel.provider_config.to_h.dig('token_health', 'status')
    token_health_status == Whatsapp::TokenInspectionService::EXPIRING_SOON_STATUS
  end

  def can_upgrade_to_embedded_signup?
    channel = @inbox.channel
    return false unless channel.provider == 'whatsapp_cloud'

    channel.provider_config.to_h['source'] != 'embedded_signup'
  end

  def render_success_response(inbox)
    inbox.reload
    channel = inbox.channel
    response = {
      success: true,
      id: inbox.id,
      avatar_url: inbox.try(:avatar_url),
      channel_id: inbox.channel_id,
      name: inbox.name,
      channel_type: inbox.display_channel_type,
      provider: channel.try(:provider),
      phone_number: channel.try(:phone_number),
      provider_config: safe_provider_config(channel),
      reauthorization_required: channel.try(:reauthorization_required?)
    }.compact
    response[:message] = I18n.t('inbox.reauthorization.success') if params[:inbox_id].present?
    render json: response
  end

  def safe_provider_config(channel)
    return nil unless Current.account_user&.administrator?

    public_config = Whatsapp::ProviderConfigPresenter.new(channel).perform
    authorization_config = channel.provider_config.to_h.slice(*AUTHORIZATION_ONLY_PROVIDER_CONFIG_KEYS)
    safe_authorization_config = Meta::CredentialDataSanitizer.sanitize(
      authorization_config,
      secrets: Meta::CredentialDataSanitizer.channel_secrets(channel)
    )
    public_config.merge(safe_authorization_config)
  end

  def render_error_response(error)
    logged_message = sanitized_authorization_error(error.message)
    safe_backtrace = sanitized_authorization_error(Array(error.backtrace).join("\n"))
    Rails.logger.error "[WHATSAPP AUTHORIZATION] Embedded signup error: #{logged_message}"
    Rails.logger.error safe_backtrace if safe_backtrace.present?

    response = {
      success: false,
      error: client_authorization_error(error)
    }.merge(error_response_details(error))

    render json: response, status: :unprocessable_content
  end

  def error_response_details(error)
    case error
    when MissingRequiredParametersError
      { error_code: 'missing_required_parameters', details: { missing_parameters: error.missing_parameters } }
    when Whatsapp::ReauthorizationService::PhoneNumberMismatchError
      { error_code: 'phone_number_mismatch' }
    when Whatsapp::EmbeddedSignupService::ReauthorizationFlowMismatchError
      { error_code: 'reauthorization_flow_mismatch' }
    when Whatsapp::EmbeddedSignupService::ReauthorizationFlowRequiredError
      { error_code: 'reauthorization_flow_required' }
    else
      { error_code: 'authorization_failed' }
    end
  end

  def sanitized_authorization_error(value)
    channel = @inbox&.channel
    secrets = [params[:code], *Meta::CredentialDataSanitizer.channel_secrets(channel)].compact_blank
    Meta::CredentialDataSanitizer.sanitize(value.to_s.first(5000), secrets: secrets)
  end

  def client_authorization_error(error)
    safe_error = error.is_a?(MissingRequiredParametersError) ||
                 error.is_a?(Whatsapp::ReauthorizationService::PhoneNumberMismatchError) ||
                 error.is_a?(Whatsapp::EmbeddedSignupService::ReauthorizationFlowMismatchError) ||
                 error.is_a?(Whatsapp::EmbeddedSignupService::ReauthorizationFlowRequiredError)
    return sanitized_authorization_error(error.message) if safe_error

    'WhatsApp authorization failed. Please check the connection details and try again.'
  end

  def validate_embedded_signup_params!
    missing_params = []
    missing_params << 'code' if params[:code].blank?
    missing_params << 'waba_id' if params[:waba_id].blank? && params[:inbox_id].blank?

    return if missing_params.empty?

    raise MissingRequiredParametersError, missing_params
  end

  def session_params
    params.permit(
      :event, :version, :current_step, :error_code, :session_id, :event_timestamp,
      :business_id, :waba_id, :phone_number_id
    )
  end
end
