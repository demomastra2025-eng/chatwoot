class Api::V1::Accounts::KaspiPay::PaymentsController < Api::V1::Accounts::BaseController
  before_action :check_authorization
  before_action :fetch_hook, only: [:create]
  before_action :fetch_payment, only: [:show]

  rescue_from KaspiPay::Error, with: :render_kaspi_pay_error
  rescue_from ActiveRecord::RecordInvalid, with: :render_record_invalid

  def show
    render json: payment_payload(@payment)
  end

  def create
    return render_invalid_amount if payment_amount <= 0

    payment = KaspiPay::PaymentCreator.new(
      hook: @hook,
      source: payment_source,
      amount: payment_amount,
      idempotency_key: params[:idempotency_key].presence || default_idempotency_key,
      payment_type: params[:payment_type].presence || 'qr'
    ).create_qr!

    render json: payment_payload(payment), status: :created
  end

  private

  def check_authorization
    authorize(:hook, :create?)
  end

  def fetch_hook
    @hook = Current.account.hooks.find_by!(app_id: 'kaspi_pay', status: 'enabled')
  end

  def fetch_payment
    @payment = Current.account.kaspi_pay_payments.find(params[:id])
  end

  def payment_source
    @payment_source ||= if params[:appointment_id].present?
                          Current.account.scheduling_appointments.find(params[:appointment_id])
                        elsif params[:conversation_id].present?
                          Current.account.conversations.find(params[:conversation_id])
                        end
  end

  def payment_amount
    @payment_amount ||= (params[:amount].presence || source_amount).to_i
  end

  def source_amount
    case payment_source
    when Scheduling::Appointment
      [payment_source.service_amount.to_i - payment_source.prepaid_amount.to_i - payment_source.settlement_amount.to_i, 0].max
    end
  end

  def default_idempotency_key
    parts = [source_key, payment_amount, params[:payment_type].presence || 'qr']
    parts << SecureRandom.uuid if payment_source.is_a?(Conversation) || payment_source.blank?

    "kaspi-pay:#{parts.join(':')}"
  end

  def source_key
    return "appointment:#{payment_source.id}" if payment_source.is_a?(Scheduling::Appointment)
    return "conversation:#{payment_source.id}" if payment_source.is_a?(Conversation)

    'manual'
  end

  def payment_payload(payment)
    {
      id: payment.id,
      payment_type: payment.payment_type,
      amount: payment.amount,
      currency: payment.currency,
      status: payment.status,
      status_description: payment.status_description,
      source_type: payment.source_type,
      source_id: payment.source_id,
      qr_token: payment.qr_token,
      receipt_url: payment.receipt_url,
      expires_at: payment.expires_at,
      paid_at: payment.paid_at,
      kaspi_operation_id: payment.kaspi_operation_id
    }
  end

  def render_invalid_amount
    render json: { error: 'Payment amount must be greater than 0', code: 'INVALID_AMOUNT' }, status: :unprocessable_content
  end

  def render_kaspi_pay_error(error)
    render json: { error: error.message, code: error.code, details: error.details }, status: error.status
  end

  def render_record_invalid(error)
    render json: { error: error.record.errors.full_messages.to_sentence, details: error.record.errors.to_hash(true) }, status: :unprocessable_content
  end
end
