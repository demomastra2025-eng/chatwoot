class Scheduling::Appointments::FinanceSyncService
  def initialize(appointment:, actor: nil)
    @appointment = appointment
    @actor = actor
  end

  def add_payment!(amount:, payment_method:)
    raise ArgumentError, 'Set service_amount before adding payment' if appointment.service_amount.to_i <= 0
    raise ArgumentError, 'Cancelled payments cannot be updated' if appointment.payment_status == 'cancelled'

    already_received = appointment.prepaid_amount.to_i + appointment.settlement_amount.to_i
    remaining = [appointment.service_amount.to_i - already_received, 0].max
    payment_amount = amount.present? ? amount.to_i : remaining

    raise ArgumentError, 'Payment amount must be greater than 0' unless payment_amount.positive?
    raise ArgumentError, 'Payment amount exceeds remaining balance' if already_received + payment_amount > appointment.service_amount.to_i

    appointment.payments.create!(
      account: appointment.account,
      recorded_by: actor,
      amount: payment_amount,
      payment_method: payment_method,
      payment_kind: 'payment'
    )

    appointment.update!(
      settlement_amount: appointment.settlement_amount.to_i + payment_amount,
      settlement_payment_method: payment_method,
      payment_status: derive_payment_status(
        appointment.service_amount,
        appointment.prepaid_amount,
        appointment.settlement_amount.to_i + payment_amount,
        appointment.payment_status
      )
    )

    sync!
  end

  def cancel_all!
    if appointment.expense.present? && appointment.expense.status == 'paid'
      raise ArgumentError, "Cannot cancel payment after the resource's expense has been paid"
    end

    appointment.payments.destroy_all
    appointment.update!(
      prepaid_amount: 0,
      prepaid_payment_method: nil,
      settlement_amount: 0,
      settlement_payment_method: nil,
      payment_status: 'cancelled'
    )

    sync!
  end

  def sync!
    validate_totals!
    upsert_payment_by_kind('prepaid', appointment.prepaid_amount, appointment.prepaid_payment_method)

    manual_payment_total = appointment.manual_payments_total
    if appointment.settlement_amount.to_i < manual_payment_total
      raise ArgumentError,
            'settlement_amount cannot be less than the total of recorded payments'
    end

    adjustment_amount = appointment.settlement_amount.to_i - manual_payment_total
    upsert_payment_by_kind('adjustment', adjustment_amount, appointment.settlement_payment_method)
    sync_expense!
    appointment.reload
  end

  private

  attr_reader :actor, :appointment

  def compute_expense_amount
    return 0 if appointment.compensation_type_snapshot.blank?
    return appointment.compensation_value_snapshot.to_i if appointment.compensation_type_snapshot == 'fixed'

    ((appointment.service_amount.to_i * appointment.compensation_value_snapshot.to_i) / 100.0).round
  end

  def derive_payment_status(service_amount, prepaid_amount, settlement_amount, requested_status = nil)
    return 'cancelled' if requested_status == 'cancelled'

    total_received = prepaid_amount.to_i + settlement_amount.to_i
    return 'awaiting_payment' if total_received <= 0
    return 'paid' if service_amount.to_i <= 0 || total_received >= service_amount.to_i

    'prepaid'
  end

  def sync_expense!
    existing_expense = appointment.expense

    if appointment.payment_status != 'paid'
      existing_expense.destroy! if existing_expense.present? && existing_expense.status != 'paid'
      return existing_expense
    end

    amount = compute_expense_amount
    return existing_expense if existing_expense.present? && existing_expense.status == 'paid'

    if existing_expense.present?
      existing_expense.update!(
        resource: appointment.resource,
        amount: amount,
        status: 'unpaid'
      )
      return existing_expense
    end

    appointment.create_expense!(
      account: appointment.account,
      resource: appointment.resource,
      amount: amount,
      status: 'unpaid'
    )
  end

  def upsert_payment_by_kind(kind, amount, payment_method)
    payment = appointment.payments.find_by(payment_kind: kind)
    normalized_amount = amount.to_i

    if normalized_amount <= 0 || payment_method.blank?
      payment&.destroy!
      return nil
    end

    attrs = {
      amount: normalized_amount,
      payment_method: payment_method,
      recorded_by: actor
    }

    return payment.tap { payment.update!(attrs) } if payment.present?

    appointment.payments.create!(
      attrs.merge(
        account: appointment.account,
        payment_kind: kind
      )
    )
  end

  def validate_totals!
    if appointment.service_amount.to_i.positive? &&
       appointment.prepaid_amount.to_i + appointment.settlement_amount.to_i > appointment.service_amount.to_i
      raise ArgumentError, 'Total received amount cannot exceed service_amount'
    end
  end
end
