# frozen_string_literal: true

class Api::V1::Accounts::KaspiPay::PaymentsController < Api::V1::Accounts::BaseController
  CLIENT_INFO_RATE_LIMIT = 20

  before_action :check_admin_authorization?, only: [:refund]
  before_action :fetch_payment, only: [:show, :refresh, :cancel, :refund]

  def index
    scope = filter_payments_scope(accessible_payments_scope.recent)
    limit = (params[:limit].presence || 25).to_i.clamp(1, 100)

    render json: {
      meta: index_meta_payload,
      payload: scope.limit(limit).map(&:as_api_payload)
    }
  end

  def show
    render json: @payment.as_api_payload
  end

  def create
    authorize_create_scope!

    payment = payment_service.create_payment!(create_params)
    render json: payment.as_api_payload, status: :created
  rescue Integrations::KaspiPay::PhoneNormalizer::InvalidPhoneError,
         Integrations::KaspiPay::PaymentService::PaymentError,
         Integrations::KaspiPay::ApiClient::ApiError => e
    render json: { error: e.message, code: e.try(:code) }, status: :unprocessable_content
  end

  def refresh
    payment = payment_service.refresh_payment!(@payment)
    render json: payment.as_api_payload
  rescue Integrations::KaspiPay::ApiClient::ApiError => e
    render json: { error: e.message, code: e.code }, status: :unprocessable_content
  end

  def cancel
    payment = payment_service.cancel_payment!(@payment)
    render json: payment.as_api_payload
  rescue Integrations::KaspiPay::PaymentService::PaymentError,
         Integrations::KaspiPay::ApiClient::ApiError => e
    render json: { error: e.message, code: e.try(:code) }, status: :unprocessable_content
  end

  def refund
    payment = payment_service.refund_payment!(@payment, return_amount: params[:amount])
    render json: payment.as_api_payload
  rescue Integrations::KaspiPay::PaymentService::PaymentError,
         Integrations::KaspiPay::ApiClient::ApiError => e
    render json: { error: e.message, code: e.try(:code) }, status: :unprocessable_content
  end

  def client_info
    authorize_create_scope!
    enforce_client_info_rate_limit!

    render json: payment_service.client_info!(raw_phone: params[:phone_number])
  rescue Integrations::KaspiPay::PhoneNormalizer::InvalidPhoneError,
         Integrations::KaspiPay::PaymentService::PaymentError,
         Integrations::KaspiPay::ApiClient::ApiError => e
    render json: { error: e.message, code: e.try(:code) }, status: :unprocessable_content
  end

  private

  def filter_payments_scope(scope)
    scope = filter_by_conversation(scope) if params[:conversation_id].present?
    scope = scope.where(appointment_id: params[:appointment_id]) if params[:appointment_id].present?
    scope = scope.where(contact_id: params[:contact_id]) if params[:contact_id].present?
    scope
  end

  def filter_by_conversation(scope)
    conv = find_account_conversation(params[:conversation_id])
    return scope.none unless conv

    authorize(conv, :show?)
    scope.where(conversation_id: conv.id)
  end

  def authorize_create_scope!
    if params[:conversation_id].present?
      authorize_target_conversation!(params[:conversation_id])
      authorize_linked_appointment! if params[:appointment_id].present?
      return
    end

    if params[:appointment_id].present?
      appt = Current.account.scheduling_appointments.find(params[:appointment_id])
      return authorize(appt.conversation, :show?) if appt.conversation.present?
    end

    check_admin_authorization?
  end

  def authorize_linked_appointment!
    appt = Current.account.scheduling_appointments.find(params[:appointment_id])
    authorize(appt.conversation, :show?) if appt.conversation.present?
  end

  def authorize_target_conversation!(conversation_id)
    conv = find_account_conversation(conversation_id)
    raise ActiveRecord::RecordNotFound, 'Conversation not found' unless conv

    authorize(conv, :show?)
  end

  def enforce_client_info_rate_limit!
    key = "kaspi_pay:client_info_rl:#{Current.account.id}:#{current_user.id}"
    count = ::Redis::Alfred.incr(key)
    ::Redis::Alfred.expire(key, 60) if count == 1
    return if count <= CLIENT_INFO_RATE_LIMIT

    raise Integrations::KaspiPay::PaymentService::PaymentError, 'Слишком много проверок номера. Подождите минуту.'
  end

  def index_meta_payload
    hook = auth_service.hook
    connected = hook.present? && hook.enabled?
    settings = hook&.settings || {}
    {
      connected: connected,
      session_status: connected ? (settings['session_status'].presence || 'active') : 'disconnected',
      organization_name: settings['organization_name'],
      auto_send_link_to_chat: settings.fetch('auto_send_link_to_chat', true)
    }
  end

  def fetch_payment
    @payment = Current.account.kaspi_pay_payments.find(params[:id])
    return authorize(@payment.conversation, :show?) if @payment.conversation.present?
    return if Current.account_user&.administrator? || @payment.created_by_id == current_user.id

    raise Pundit::NotAuthorizedError
  end

  def find_account_conversation(identifier)
    Current.account.conversations.find_by(display_id: identifier)
  end

  def accessible_payments_scope
    base = Current.account.kaspi_pay_payments
    return base if Current.account_user&.administrator?

    accessible_conv_ids = Conversations::PermissionFilterService.new(
      Current.account.conversations, current_user, Current.account
    ).perform.select(:id)

    base.where(conversation_id: accessible_conv_ids).or(base.where(conversation_id: nil, created_by_id: current_user.id))
  end

  def auth_service
    @auth_service ||= Integrations::KaspiPay::AuthService.new(account: Current.account)
  end

  def payment_service
    @payment_service ||= Integrations::KaspiPay::PaymentService.new(account: Current.account, actor: current_user)
  end

  def create_params
    params.permit(
      :payment_type, :amount, :payer_phone, :comment,
      :conversation_id, :contact_id, :appointment_id, :crm_deal_id, :send_to_conversation
    )
  end
end
