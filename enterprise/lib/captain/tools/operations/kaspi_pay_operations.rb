require 'bigdecimal'
require 'digest'

class Captain::Tools::Operations::KaspiPayOperations
  DEFAULT_PAYMENT_TYPE = 'qr'.freeze
  ACTIVE_PAYMENT_STATUSES = %w[pending].freeze
  DELIVERY_MODES = %w[none link qr_image].freeze

  def initialize(assistant:, conversation: nil, actor: nil)
    @assistant = assistant
    @conversation = conversation
    @actor = actor
  end

  def integration_status(live_check: false)
    ensure_account_admin!

    hook = account.hooks.find_by(app_id: 'kaspi_pay')
    provider_session = provider_session_status(hook, live_check: truthy?(live_check))

    {
      action: 'get_kaspi_pay_integration_status',
      connected: hook&.enabled? || false,
      local_status: hook&.status || 'not_configured',
      provider_session: provider_session,
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

  def create_current_conversation_payment(amount: nil, payment_type: DEFAULT_PAYMENT_TYPE, idempotency_key: nil, phone_number: nil, comment: nil,
                                          delivery_mode: 'link')
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?

    source = current_appointment || conversation

    create_payment(
      source: source,
      amount: amount.presence || source_amount(source),
      payment_type: payment_type,
      idempotency_key: idempotency_key,
      phone_number: phone_number,
      comment: comment,
      delivery_mode: delivery_mode
    )
  end

  def create_account_payment(amount: nil, payment_type: DEFAULT_PAYMENT_TYPE, idempotency_key: nil, conversation_id: nil, appointment_id: nil,
                             phone_number: nil, comment: nil, delivery_mode: 'none')
    ensure_account_admin!

    source = source_for(conversation_id: conversation_id, appointment_id: appointment_id)

    create_payment(
      source: source,
      amount: amount.presence || source_amount(source),
      payment_type: payment_type,
      idempotency_key: idempotency_key,
      phone_number: phone_number,
      comment: comment,
      delivery_mode: delivery_mode
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

  def cancel_invoice(payment_id:)
    ensure_account_admin!

    payment = account.kaspi_pay_payments.find(payment_id)
    payment = KaspiPay::InvoiceCancellationService.new(payment: payment).cancel!

    {
      action: 'cancel_kaspi_pay_invoice',
      payment: KaspiPay::PayloadBuilder.payment(payment)
    }
  end

  def provider_history(kind:, end_date: nil, last_transaction_date: nil, statement_period_code: 0)
    ensure_account_admin!

    normalized_kind = kind.to_s
    raise ArgumentError, 'kind must be operations or invoices' unless normalized_kind.in?(%w[operations invoices])

    history = KaspiPay::HistoryService.new(hook: enabled_hook!)
    data = if normalized_kind == 'operations'
             history.operations(
               end_date: normalize_history_date(end_date.presence || Date.current.iso8601, 'end_date'),
               last_transaction_date: normalize_optional_history_date(last_transaction_date),
               statement_period_code: statement_period_code.to_i
             )
           else
             history.invoice_history
           end

    {
      action: 'get_kaspi_pay_provider_history',
      kind: normalized_kind,
      data: data
    }
  end

  def client_info(phone_number:)
    ensure_account_admin!

    normalized_phone = phone_number.to_s.gsub(/\D/, '')
    raise ArgumentError, 'phone_number must contain 10 or 11 digits' unless normalized_phone.length.in?([10, 11])

    response = KaspiPay::Client.new(hook: enabled_hook!).client_info(normalized_phone)
    if response['StatusCode'].present? && response['StatusCode'].to_i != 0
      raise KaspiPay::Error.new('Kaspi Pay client lookup failed', details: response)
    end

    data = response['Data'] || response['data'] || {}

    {
      action: 'get_kaspi_pay_client_info',
      found: data['ClientName'].present?,
      phone_number: mask_phone(normalized_phone),
      client_name: data['ClientName'],
      client_status: data['ClientStatus']
    }.compact
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

  def create_payment(source:, amount:, payment_type:, idempotency_key:, delivery_mode:, phone_number: nil, comment: nil)
    normalized_amount = normalize_amount(amount)
    normalized_payment_type = normalize_payment_type(payment_type)
    normalized_delivery_mode = normalize_delivery_mode(delivery_mode, payment_type: normalized_payment_type)
    hook = enabled_hook!
    creator = KaspiPay::PaymentCreator.new(
      hook: hook,
      source: source,
      amount: normalized_amount,
      idempotency_key: idempotency_key.presence || default_idempotency_key(
        source: source,
        amount: normalized_amount,
        payment_type: normalized_payment_type,
        phone_number: phone_number,
        comment: comment
      ),
      payment_type: normalized_payment_type,
      phone_number: phone_number,
      comment: comment
    )
    payment = normalized_payment_type == 'invoice' ? creator.create_invoice! : creator.create_qr!
    delivery = deliver_payment(payment, mode: normalized_delivery_mode)

    {
      action: 'create_kaspi_pay_payment',
      payment: KaspiPay::PayloadBuilder.payment(payment),
      delivery: delivery
    }.compact
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

  def normalize_delivery_mode(delivery_mode, payment_type:)
    normalized = delivery_mode.presence || 'none'
    raise ArgumentError, "delivery_mode must be one of: #{DELIVERY_MODES.join(', ')}" unless normalized.in?(DELIVERY_MODES)
    raise ArgumentError, 'invoice payments must use delivery_mode none' if payment_type == 'invoice' && normalized != 'none'

    normalized
  end

  def deliver_payment(payment, mode:)
    return if mode == 'none'

    target_conversation = payment_conversation(payment)
    raise ArgumentError, 'Kaspi Pay delivery requires a linked conversation' if target_conversation.blank?

    KaspiPay::ConversationDeliveryService.new(
      payment: payment,
      conversation: target_conversation,
      sender: actor || assistant
    ).deliver!(mode: mode)
  end

  def payment_conversation(payment)
    return payment.source if payment.source_type == 'Conversation'
    return payment.source&.conversation if payment.source_type == 'Scheduling::Appointment'
  end

  def default_idempotency_key(source:, amount:, payment_type:, phone_number:, comment:)
    source_key = case source
                 when Scheduling::Appointment
                   "appointment:#{source.id}"
                 when Conversation
                   "conversation:#{source.id}"
                 else
                   'manual'
                 end
    request_anchor = copilot_request_anchor || source_request_anchor(source)
    detail_digest = Digest::SHA256.hexdigest([phone_number.to_s.gsub(/\D/, ''), comment.to_s].join(':')).first(16)

    "captain-kaspi-pay:#{source_key}:request:#{request_anchor}:#{amount}:#{payment_type}:#{detail_digest}"
  end

  def copilot_request_anchor
    return unless actor.is_a?(User)

    request_id = Llm::EventBus.request_id
    "captain-request:#{request_id}" if request_id.present?
  end

  def source_request_anchor(source)
    source_conversation = source.is_a?(Conversation) ? source : source.try(:conversation)
    incoming_message_id = source_conversation&.messages&.incoming&.order(created_at: :desc, id: :desc)&.pick(:id)

    incoming_message_id || "source-created:#{source.created_at.to_f}"
  end

  def provider_session_status(hook, live_check:)
    return { checked: false, status: 'not_checked' } unless live_check
    return { checked: true, healthy: false, status: 'not_connected' } unless hook&.enabled?

    KaspiPay::AuthService.new(account: account, client: KaspiPay::Client.new(hook: hook)).refresh!(hook: hook)
    {
      checked: true,
      healthy: true,
      status: 'active',
      checked_at: Time.current.iso8601
    }
  rescue KaspiPay::Error => e
    {
      checked: true,
      healthy: false,
      status: 'unavailable',
      error_code: e.code,
      message: e.message.to_s.first(200),
      checked_at: Time.current.iso8601
    }
  end

  def ensure_account_admin!
    account_user = AccountUser.find_by(account_id: account.id, user_id: actor&.id)
    return if account_user&.administrator?

    raise ArgumentError, 'Kaspi Pay admin tools require an account administrator'
  end

  def normalize_history_date(value, field_name)
    Date.iso8601(value.to_s).iso8601
  rescue Date::Error
    raise ArgumentError, "#{field_name} must be an ISO date (YYYY-MM-DD)"
  end

  def normalize_optional_history_date(value)
    return if value.blank?

    normalize_history_date(value, 'last_transaction_date')
  end

  def mask_phone(phone_number)
    "#{phone_number.first(2)}*****#{phone_number.last(4)}"
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
