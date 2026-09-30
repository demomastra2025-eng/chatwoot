# Lets the dashboard register a WhatsApp Embedded Signup attempt right after it opens
# Meta, and lets a resumed or reloaded (mobile) tab read that attempt's outcome.
# The nonce travels only in the JSON body (never in the URL) and is filtered from logs.
class Api::V1::Accounts::Whatsapp::EmbeddedSignupAttemptsController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?
  before_action :load_attempt

  # POST /api/v1/accounts/:account_id/whatsapp/embedded_signup_attempt
  def create
    @attempt.register(signup_type: params[:signup_type])
    Rails.logger.info(
      {
        event: 'whatsapp_embedded_signup_attempt',
        phase: 'started',
        account_id: Current.account.id,
        user_id: Current.user&.id,
        attempt: @attempt.reference,
        signup_type: params[:signup_type].presence,
        mobile: mobile_user_agent?
      }.compact.to_json
    )
    render json: @attempt.client_state, status: :created
  end

  # POST /api/v1/accounts/:account_id/whatsapp/embedded_signup_attempt/status
  def status
    render json: @attempt.client_state
  end

  private

  def load_attempt
    @attempt = Whatsapp::EmbeddedSignupAttempt.new(account: Current.account, user: Current.user, nonce: params[:signup_nonce])
  rescue Whatsapp::EmbeddedSignupAttempt::InvalidNonceError
    render json: { error: 'Invalid WhatsApp signup attempt', error_code: 'invalid_signup_attempt' }, status: :unprocessable_content
  end

  def mobile_user_agent?
    request.user_agent.to_s.match?(/Mobile|Android|iPhone|iPad/)
  end
end
