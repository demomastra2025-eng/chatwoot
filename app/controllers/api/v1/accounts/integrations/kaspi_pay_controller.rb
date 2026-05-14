class Api::V1::Accounts::Integrations::KaspiPayController < Api::V1::Accounts::BaseController
  before_action :check_authorization
  before_action :fetch_hook, only: [:destroy]

  rescue_from KaspiPay::Error, with: :render_kaspi_pay_error
  rescue_from ActiveRecord::RecordInvalid, with: :render_record_invalid

  def init
    render json: KaspiPay::AuthService.new(account: Current.account).init
  end

  def send_phone
    render json: KaspiPay::AuthService.new(account: Current.account).send_phone(
      process_id: params.require(:process_id),
      phone_number: params.require(:phone_number)
    )
  end

  def verify_otp
    service = KaspiPay::AuthService.new(account: Current.account)
    session = service.verify_otp(
      process_id: params.require(:process_id),
      otp: params.require(:otp),
      phone_number: params[:phone_number]
    )
    hook = service.connect!(session: session, settings: kaspi_pay_settings)

    render json: hook_payload(hook)
  end

  def destroy
    @hook.update!(status: 'disabled', access_token: nil)
    head :ok
  end

  private

  def check_authorization
    authorize(:hook, :create?)
  end

  def fetch_hook
    @hook = Current.account.hooks.find_by!(app_id: 'kaspi_pay')
  end

  def hook_payload(hook)
    {
      id: hook.id,
      app_id: hook.app_id,
      status: hook.enabled?,
      account_id: hook.account_id,
      hook_type: hook.hook_type,
      settings: hook.settings,
      metadata: hook.kaspi_pay_metadata
    }
  end

  def kaspi_pay_settings
    params.fetch(:settings, {}).permit(:default_payment_type, :latitude, :longitude).to_h
  end

  def render_kaspi_pay_error(error)
    render json: { error: error.message, code: error.code, details: error.details }, status: error.status
  end

  def render_record_invalid(error)
    render json: { error: error.record.errors.full_messages.to_sentence, details: error.record.errors.to_hash(true) }, status: :unprocessable_content
  end
end
