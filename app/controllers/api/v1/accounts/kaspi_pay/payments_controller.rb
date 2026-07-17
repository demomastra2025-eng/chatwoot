class Api::V1::Accounts::KaspiPay::PaymentsController < Api::V1::Accounts::BaseController
  before_action :check_authorization
  before_action :fetch_hook, only: [:create, :history, :history_details, :invoice_history]
  before_action :fetch_payment, only: [:show, :refund, :cancel]

  rescue_from KaspiPay::Error, with: :render_kaspi_pay_error
  rescue_from ActiveRecord::RecordInvalid, with: :render_record_invalid

  def show
    render json: payment_payload(@payment)
  end

  def create
    return render_invalid_amount if payment_amount <= 0

    creator = KaspiPay::PaymentCreator.new(
      hook: @hook,
      source: payment_source,
      amount: payment_amount,
      idempotency_key: params[:idempotency_key].presence || default_idempotency_key,
      payment_type: payment_type,
      phone_number: params[:phone_number],
      comment: params[:comment]
    )
    payment = payment_type == 'invoice' ? creator.create_invoice! : creator.create_qr!

    render json: payment_payload(payment), status: :created
  end

  def refund
    payment = KaspiPay::RefundService.new(payment: @payment, return_amount: params[:amount]).refund!
    render json: payment_payload(payment.reload)
  end

  def cancel
    payment = KaspiPay::InvoiceCancellationService.new(payment: @payment).cancel!
    render json: payment_payload(payment.reload)
  end

  def history
    render json: KaspiPay::HistoryService.new(hook: @hook).operations(
      end_date: params[:end_date].presence || Date.current.iso8601,
      last_transaction_date: params[:last_transaction_date],
      statement_period_code: params[:statement_period_code].presence || 0
    )
  end

  def history_details
    render json: KaspiPay::HistoryService.new(hook: @hook).operation_details(
      id: params.require(:id),
      operation_method: params[:operation_method].presence || 0
    )
  end

  def invoice_history
    render json: KaspiPay::HistoryService.new(hook: @hook).invoice_history
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
                          find_conversation_source(params[:conversation_id])
                        end
  end

  def find_conversation_source(identifier)
    Current.account.conversations.find_by(id: identifier) ||
      Current.account.conversations.find_by!(display_id: identifier)
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
    parts = [source_key, payment_amount, payment_type]
    parts << SecureRandom.uuid if payment_source.is_a?(Conversation) || payment_source.blank?

    "kaspi-pay:#{parts.join(':')}"
  end

  def source_key
    return "appointment:#{payment_source.id}" if payment_source.is_a?(Scheduling::Appointment)
    return "conversation:#{payment_source.id}" if payment_source.is_a?(Conversation)

    'manual'
  end

  def payment_type
    return @payment_type if defined?(@payment_type)

    requested_type = params[:payment_type].presence
    if requested_type.present? && KaspiPay::Payment::PAYMENT_TYPES.exclude?(requested_type)
      raise KaspiPay::Error.new('payment_type must be qr or invoice', code: 'INVALID_PAYMENT_TYPE')
    end

    @payment_type = requested_type || 'qr'
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
      qr_original_token: payment.qr_original_token,
      receipt_url: payment.receipt_url,
      expires_at: payment.expires_at,
      paid_at: payment.paid_at,
      kaspi_operation_id: payment.kaspi_operation_id,
      kaspi_order_number: payment.kaspi_order_number,
      refund_amount: payment.metadata.to_h['refund_amount']
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
