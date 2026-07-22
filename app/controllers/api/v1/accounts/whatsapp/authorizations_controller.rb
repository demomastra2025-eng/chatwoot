class Api::V1::Accounts::Whatsapp::AuthorizationsController < Api::V1::Accounts::BaseController
  SAFE_PROVIDER_CONFIG_KEYS = %w[
    phone_number_id
    business_account_id
    business_id
    source
    calling_enabled
    calling_capable
    calling_capabilities
    token_health
  ].freeze

  class MissingRequiredParametersError < ArgumentError
    attr_reader :missing_parameters

    def initialize(missing_parameters)
      @missing_parameters = missing_parameters
      super("Required parameters are missing: #{missing_parameters.join(', ')}")
    end
  end

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

  private

  def process_embedded_signup
    service = Whatsapp::EmbeddedSignupService.new(
      account: Current.account,
      params: params.permit(:code, :business_id, :waba_id, :phone_number_id).to_h.symbolize_keys,
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

    channel.provider_config.to_h.slice(*SAFE_PROVIDER_CONFIG_KEYS)
  end

  def render_error_response(error)
    Rails.logger.error "[WHATSAPP AUTHORIZATION] Embedded signup error: #{error.message}"
    Rails.logger.error error.backtrace.join("\n") if error.backtrace.present?

    response = {
      success: false,
      error: error.message
    }

    if error.is_a?(MissingRequiredParametersError)
      response[:error_code] = 'missing_required_parameters'
      response[:details] = { missing_parameters: error.missing_parameters }
    end

    render json: response, status: :unprocessable_content
  end

  def validate_embedded_signup_params!
    missing_params = []
    missing_params << 'code' if params[:code].blank?
    missing_params << 'business_id' if params[:business_id].blank?
    missing_params << 'waba_id' if params[:waba_id].blank?
    missing_params << 'phone_number_id' if params[:phone_number_id].blank?

    return if missing_params.empty?

    raise MissingRequiredParametersError, missing_params
  end
end
