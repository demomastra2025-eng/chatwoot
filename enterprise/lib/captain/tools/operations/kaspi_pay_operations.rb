require 'bigdecimal'

class Captain::Tools::Operations::KaspiPayOperations
  DEFAULT_PAYMENT_TYPE = 'qr'.freeze
  ACTIVE_PAYMENT_STATUSES = %w[pending].freeze

  def initialize(assistant:, conversation: nil, actor: nil)
    @assistant = assistant
    @conversation = conversation
    @actor = actor
  end

  def integration_status
    ensure_account_admin!

    hook = account.hooks.find_by(app_id: 'kaspi_pay')

    {
      action: 'get_kaspi_pay_integration_status',
      connected: hook&.enabled? || false,
      hook: KaspiPay::PayloadBuilder.hook(hook)
    }
  end

  def start_connection
    ensure_account_admin!

    KaspiPay::AuthService.new(account: account).init.merge(action: 'start_kaspi_pay_connection')
  end

  def send_phone(process_id:, phone_number:)
    ensure_account_admin!
    raise ArgumentError, 'process_id is required' if process_id.blank?
    raise ArgumentError, 'phone_number is required' if phone_number.blank?

    KaspiPay::AuthService.new(account: account).send_phone(
      process_id: process_id,
      phone_number: phone_number
    ).merge(action: 'send_kaspi_pay_phone')
  end

  def verify_otp(process_id:, otp:, phone_number: nil, settings: {})
    ensure_account_admin!
    raise ArgumentError, 'process_id is required' if process_id.blank?
    raise ArgumentError, 'otp is required' if otp.blank?

    service = KaspiPay::AuthService.new(account: account)
    session = service.verify_otp(process_id: process_id, otp: otp, phone_number: phone_number)
    hook = service.connect!(session: session, settings: settings)

    {
      action: 'verify_kaspi_pay_otp',
      connected: hook.enabled?,
      hook: KaspiPay::PayloadBuilder.hook(hook)
    }
  end

  def disconnect!
    ensure_account_admin!

    hook = account.hooks.find_by(app_id: 'kaspi_pay')
    return { action: 'disconnect_kaspi_pay', connected: false } if hook.blank?

    hook.update!(status: 'disabled', access_token: nil)

    { action: 'disconnect_kaspi_pay', connected: false, hook_id: hook.id }
  end

  def create_current_conversation_payment(amount: nil, payment_type: DEFAULT_PAYMENT_TYPE, idempotency_key: nil, phone_number: nil, comment: nil)
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?

    source = current_appointment || conversation

    create_payment(
      source: source,
      amount: amount.presence || source_amount(source),
      payment_type: payment_type,
      idempotency_key: idempotency_key,
      phone_number: phone_number,
      comment: comment
    )
  end

  def create_account_payment(amount: nil, payment_type: DEFAULT_PAYMENT_TYPE, idempotency_key: nil, conversation_id: nil, appointment_id: nil,
                             phone_number: nil, comment: nil)
    ensure_account_admin!

    source = source_for(conversation_id: conversation_id, appointment_id: appointment_id)

    create_payment(
      source: source,
      amount: amount.presence || source_amount(source),
      payment_type: payment_type,
      idempotency_key: idempotency_key,
      phone_number: phone_number,
      comment: comment
    )
  end

  def current_payment_status(payment_id: nil, sync: false)
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?

    payment = if payment_id.present?
                account.kaspi_pay_payments.find(payment_id)
              else
                current_payment_scope.order(created_at: :desc).first
              end
    raise ActiveRecord::RecordNotFound, 'Kaspi Pay payment not found for the current conversation' if payment.blank?
    raise ActiveRecord::RecordNotFound, 'Kaspi Pay payment not found for the current conversation' unless current_payment?(payment)

    payment = sync_payment(payment) if truthy?(sync)

    {
      action: 'get_kaspi_pay_payment_status',
      payment: KaspiPay::PayloadBuilder.payment(payment)
    }
  end

  def search_payments(status: nil, source_type: nil, conversation_id: nil, appointment_id: nil, from: nil, to: nil, limit: nil)
    ensure_account_admin!

    scope = account.kaspi_pay_payments.includes(:source).order(created_at: :desc)
    scope = scope.where(status: status) if status.present?
    scope = scope.where(source_type: source_type) if source_type.present?
    scope = scope.where(source: account.conversations.find_by!(display_id: conversation_id)) if conversation_id.present?
    scope = scope.where(source: account.scheduling_appointments.find(appointment_id)) if appointment_id.present?
    scope = scope.where('created_at >= ?', parse_datetime(from, 'from')) if from.present?
    scope = scope.where('created_at <= ?', parse_datetime(to, 'to')) if to.present?

    total_count = scope.count
    payments = scope.limit(parse_limit(limit)).map { |payment| KaspiPay::PayloadBuilder.payment(payment) }

    {
      action: 'search_kaspi_pay_payments',
      filters: {
        status: status,
        source_type: source_type,
        conversation_id: conversation_id,
        appointment_id: appointment_id,
        from: from,
        to: to
      }.compact,
      total_count: total_count,
      payments: payments
    }
  end

  def refund_payment(payment_id:, amount:)
    ensure_account_admin!

    payment = account.kaspi_pay_payments.find(payment_id)
    payment = KaspiPay::RefundService.new(payment: payment, return_amount: amount).refund!

    {
      action: 'refund_kaspi_pay_payment',
      payment: KaspiPay::PayloadBuilder.payment(payment)
    }
  end

  def reconcile_payment(payment_id:, operation_method: 0)
    ensure_account_admin!

    payment = account.kaspi_pay_payments.find(payment_id)
    payment = KaspiPay::HistoryReconciliationService.new(payment: payment, operation_method: operation_method).sync!

    {
      action: 'reconcile_kaspi_pay_payment',
      payment: KaspiPay::PayloadBuilder.payment(payment)
    }
  end

  def get_payment(payment_id:, sync: false)
    ensure_account_admin!

    payment = account.kaspi_pay_payments.find(payment_id)
    payment = sync_payment(payment) if truthy?(sync)

    {
      action: 'get_kaspi_pay_payment',
      payment: KaspiPay::PayloadBuilder.payment(payment)
    }
  end

  def sync_payment_status(payment_id:)
    ensure_account_admin!

    payment = account.kaspi_pay_payments.find(payment_id)
    payment = sync_payment(payment)

    {
      action: 'sync_kaspi_pay_payment_status',
      payment: KaspiPay::PayloadBuilder.payment(payment)
    }
  end

  private

  attr_reader :actor, :assistant, :conversation

  def account
    assistant.account
  end

  def create_payment(source:, amount:, payment_type:, idempotency_key:, phone_number: nil, comment: nil)
    normalized_amount = normalize_amount(amount)
    normalized_payment_type = normalize_payment_type(payment_type)
    hook = enabled_hook!
    creator = KaspiPay::PaymentCreator.new(
      hook: hook,
      source: source,
      amount: normalized_amount,
      idempotency_key: idempotency_key.presence || default_idempotency_key(source: source, amount: normalized_amount,
                                                                           payment_type: normalized_payment_type),
      payment_type: normalized_payment_type,
      phone_number: phone_number,
      comment: comment
    )
    payment = normalized_payment_type == 'invoice' ? creator.create_invoice! : creator.create_qr!

    {
      action: 'create_kaspi_pay_payment',
      payment: KaspiPay::PayloadBuilder.payment(payment)
    }
  end

  def source_for(conversation_id:, appointment_id:)
    return account.scheduling_appointments.find(appointment_id) if appointment_id.present?

    if conversation_id.present?
      return account.conversations.find_by(id: conversation_id) || account.conversations.find_by!(display_id: conversation_id)
    end

    conversation || raise(ArgumentError, 'conversation_id or appointment_id is required')
  end

  def current_appointment
    return if conversation.blank?

    Captain::ContextFields.appointment_for(account: account, conversation: conversation)
  end

  def enabled_hook!
    account.hooks.find_by!(app_id: 'kaspi_pay', status: 'enabled')
  rescue ActiveRecord::RecordNotFound
    raise ArgumentError, 'Kaspi Pay is not connected for this account'
  end

  def current_payment_scope
    [conversation, current_appointment].compact.reduce(account.kaspi_pay_payments.none) do |scope, source|
      scope.or(account.kaspi_pay_payments.where(source: source))
    end
  end

  def current_payment?(payment)
    [conversation, current_appointment].compact.any?(payment.source)
  end

  def sync_payment(payment)
    return payment if payment.final_status?

    KaspiPay::StatusSyncService.new(payment: payment).sync!
  end

  def source_amount(source)
    case source
    when Scheduling::Appointment
      [source.service_amount.to_i - source.prepaid_amount.to_i - source.settlement_amount.to_i, 0].max
    end
  end

  def normalize_amount(amount)
    raise ArgumentError, 'amount is required' if amount.blank?

    value = BigDecimal(amount.to_s)
    raise ArgumentError, 'amount must be a whole number in KZT' unless value.positive? && value.frac.zero?

    value.to_i
  rescue ArgumentError, TypeError
    raise ArgumentError, 'amount must be a whole number in KZT'
  end

  def normalize_payment_type(payment_type)
    normalized = payment_type.presence || DEFAULT_PAYMENT_TYPE
    return normalized if normalized.in?(KaspiPay::Payment::PAYMENT_TYPES)

    raise ArgumentError, 'payment_type must be qr or invoice'
  end

  def default_idempotency_key(source:, amount:, payment_type:)
    source_key = case source
                 when Scheduling::Appointment
                   "appointment:#{source.id}"
                 when Conversation
                   "conversation:#{source.id}"
                 else
                   'manual'
                 end

    "captain-kaspi-pay:#{source_key}:#{amount}:#{payment_type}:#{SecureRandom.uuid}"
  end

  def ensure_account_admin!
    account_user = AccountUser.find_by(account_id: account.id, user_id: actor&.id)
    return if account_user&.administrator?

    raise ArgumentError, 'Kaspi Pay admin tools require an account administrator'
  end

  def parse_datetime(value, field_name)
    parsed = Time.zone.parse(value.to_s)
    raise ArgumentError, "#{field_name} must be a valid datetime" if parsed.blank?

    parsed
  end

  def parse_limit(value, default: 20, max: 50)
    return default if value.blank?

    numeric = value.to_i
    return default if numeric <= 0

    [numeric, max].min
  end

  def truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end
end
