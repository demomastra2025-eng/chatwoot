# frozen_string_literal: true

class Integrations::KaspiPay::AppointmentReconciler
  def initialize(account:, actor: nil)
    @account = account
    @actor = actor
  end

  def self.format_tenge(value)
    "#{value.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1 ').reverse} ₸"
  end

  def build_payment_context(params, hook:)
    conversation = resolve_conversation!(params[:conversation_id])
    appointment = resolve_record!(@account.scheduling_appointments, params[:appointment_id], 'Запись не найдена')
    crm_deal = resolve_record!(@account.crm_deals, params[:crm_deal_id], 'Сделка не найдена')
    explicit_contact = resolve_record!(@account.contacts, params[:contact_id], 'Контакт не найден')
    contact = explicit_contact || appointment&.contact || conversation&.contact
    validate_context_consistency!(conversation, appointment, contact, crm_deal)
    {
      hook: hook, contact: contact, conversation: conversation,
      appointment: appointment, crm_deal: crm_deal, created_by: @actor,
      comment: params[:comment].to_s.strip.truncate(140).presence
    }
  end

  def record_payment!(payment)
    appointment = valid_appointment(payment)
    return unless appointment

    appointment.with_lock do
      meta = (payment.reload.metadata || {}).dup
      return if meta['reconciled_scheduling_payment_id'].present?

      sched_payment = create_scheduling_payment!(appointment, amount: payment.amount, kind: 'payment', actor: payment.created_by)
      sync_appointment_payment_state!(appointment)
      payment.update!(metadata: meta.merge('reconciled_scheduling_payment_id' => sched_payment.id))
    end
    sync_finance!(appointment, payment.created_by)
  rescue StandardError => e
    Rails.logger.error("[KaspiPay] Failed to reconcile appointment ##{appointment&.id} for payment ##{payment.id}: #{e.class} #{e.message}")
  end

  def record_refund!(payment, amount_returned:)
    appointment = valid_appointment(payment)
    return unless appointment

    refund_token = "refund_#{payment.refunded_amount}_#{amount_returned.to_i}"
    appointment.with_lock do
      meta = (payment.reload.metadata || {}).dup
      recorded = Array(meta['reconciled_refunds'])
      return if recorded.include?(refund_token)

      create_scheduling_payment!(appointment, amount: -amount_returned.to_i, kind: 'refund', actor: @actor)
      sync_appointment_payment_state!(appointment)
      payment.update!(metadata: meta.merge('reconciled_refunds' => recorded + [refund_token]))
    end
    sync_finance!(appointment, @actor)
  rescue StandardError => e
    Rails.logger.error("[KaspiPay] Failed to reconcile refund on appointment ##{appointment&.id}: #{e.class} #{e.message}")
  end

  def post_creation_messages!(payment, send_to_conversation:)
    conversation = payment.conversation
    return if conversation.blank?

    if payment.payment_type == 'qr'
      send_outgoing_payment_link(conversation, payment) if send_to_conversation && @actor.present?
      post_activity!(conversation, "Создана ссылка Kaspi Pay ##{payment.qr_operation_id} на #{format_tenge(payment.amount)}.")
    else
      post_activity!(
        conversation,
        "Выставлен счёт Kaspi Pay ##{payment.qr_operation_id} на #{format_tenge(payment.amount)} (#{payment.payer_phone_masked})."
      )
    end
  rescue StandardError => e
    Rails.logger.warn("[KaspiPay] Could not post conversation message for payment ##{payment.id}: #{e.class} #{e.message}")
  end

  def post_activity!(conversation, content)
    return if conversation.blank? || content.blank?

    ::Conversations::ActivityMessageJob.perform_later(
      conversation,
      {
        account_id: conversation.account_id,
        inbox_id: conversation.inbox_id,
        message_type: :activity,
        content: content
      }
    )
  end

  private

  def format_tenge(value)
    self.class.format_tenge(value)
  end

  def resolve_conversation!(conversation_id)
    return nil if conversation_id.blank?

    conv = @account.conversations.find_by(display_id: conversation_id)
    raise Integrations::KaspiPay::PaymentService::PaymentError, 'Диалог не найден' unless conv

    conv
  end

  def resolve_record!(scope, raw_id, error_msg)
    return nil if raw_id.blank?

    rec = scope.find_by(id: raw_id)
    raise Integrations::KaspiPay::PaymentService::PaymentError, error_msg unless rec

    rec
  end

  def same_optional_id?(first_id, second_id)
    first_id.blank? || second_id.blank? || first_id == second_id
  end

  def validate_context_consistency!(conversation, appointment, contact, crm_deal)
    validate_conversation_links!(conversation, appointment, contact) if conversation
    unless same_optional_id?(appointment&.contact_id, contact&.id)
      raise Integrations::KaspiPay::PaymentService::PaymentError, 'Контакт не совпадает с пациентом записи'
    end
    return if same_optional_id?(crm_deal&.contact_id, contact&.id)

    raise Integrations::KaspiPay::PaymentService::PaymentError, 'Сделка не относится к выбранному контакту'
  end

  def validate_conversation_links!(conversation, appointment, contact)
    unless same_optional_id?(conversation.contact_id, contact&.id)
      raise Integrations::KaspiPay::PaymentService::PaymentError, 'Контакт не совпадает с пациентом выбранного диалога'
    end
    return unless appointment
    return if same_optional_id?(appointment.conversation_id, conversation.id) && same_optional_id?(appointment.contact_id, conversation.contact_id)

    raise Integrations::KaspiPay::PaymentService::PaymentError, 'Запись не относится к выбранному диалогу'
  end

  def valid_appointment(payment)
    appointment = payment.appointment
    return nil if appointment.blank? || appointment.account_id != @account.id

    appointment
  end

  def create_scheduling_payment!(appointment, amount:, kind:, actor:)
    appointment.payments.create!(
      account: @account, amount: amount, payment_kind: kind, payment_method: 'kaspi_pay', recorded_by: actor
    )
  end

  def sync_appointment_payment_state!(appointment)
    total_paid = [appointment.payments.sum(:amount), 0].max
    return appointment.update!(payment_status: 'awaiting_payment', prepaid_amount: 0, settlement_amount: 0) if total_paid <= 0

    target = appointment.service_amount.to_i
    if target.positive? && total_paid < target
      appointment.update!(payment_status: 'prepaid', prepaid_amount: total_paid, prepaid_payment_method: 'kaspi_pay', settlement_amount: 0)
    else
      settled = [total_paid - appointment.prepaid_amount.to_i, 0].max
      appointment.update!(payment_status: 'paid', settlement_amount: settled, settlement_payment_method: 'kaspi_pay')
    end
  end

  def sync_finance!(appointment, actor)
    Scheduling::Appointments::FinanceSyncService.new(appointment: appointment, actor: actor).sync!
  end

  def send_outgoing_payment_link(conversation, payment)
    lines = ["Счёт на оплату: #{format_tenge(payment.amount)}"]
    lines << payment.comment if payment.comment.present?
    lines << "Оплатить в Kaspi.kz: #{payment.pay_url}" if payment.pay_url.present?
    Messages::MessageBuilder.new(
      @actor, conversation, ActionController::Parameters.new(content: lines.join("\n"), private: false)
    ).perform
  end
end
