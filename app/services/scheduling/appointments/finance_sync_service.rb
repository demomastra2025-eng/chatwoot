class Scheduling::Appointments::FinanceSyncService
  def initialize(appointment:, actor: nil)
    @appointment = appointment
    @actor = actor
  end

  def add_payment!(amount:, payment_method:)
    ensure_payment_can_be_updated!

    payment_amount = resolve_payment_amount(amount)
    ensure_required_fields_for_paid_payment! if next_payment_status_for(payment_amount) == 'paid'
    create_manual_payment!(payment_amount, payment_method)
    apply_payment!(payment_amount, payment_method)

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

  def apply_payment!(payment_amount, payment_method)
    next_settlement_amount = appointment.settlement_amount.to_i + payment_amount

    appointment.update!(
      settlement_amount: next_settlement_amount,
      settlement_payment_method: payment_method,
      payment_status: derive_payment_status(
        appointment.service_amount,
        appointment.prepaid_amount,
        next_settlement_amount,
        appointment.payment_status
      )
    )
  end

  def create_manual_payment!(payment_amount, payment_method)
    appointment.payments.create!(
      account: appointment.account,
      recorded_by: actor,
      amount: payment_amount,
      payment_method: payment_method,
      payment_kind: 'payment'
    )
  end

  def ensure_required_fields_for_paid_payment!
    inspector = Crm::RequiredFieldsInspector.new(
      account: appointment.account,
      entity_kind: 'appointment',
      custom_attributes: appointment.custom_attributes
    )
    return if inspector.complete?

    raise Scheduling::Error.new(
      code: 'APPOINTMENT_PAYMENT_REQUIRES_FIELDS',
      message: "Complete required fields before marking the appointment as paid: #{inspector.missing_field_labels.join(', ')}",
      status: :unprocessable_content,
      details: {
        missing_fields: inspector.missing_field_details
      }
    )
  end

  def next_payment_status_for(payment_amount)
    derive_payment_status(
      appointment.service_amount,
      appointment.prepaid_amount,
      appointment.settlement_amount.to_i + payment_amount.to_i,
      appointment.payment_status
    )
  end

  def ensure_payment_can_be_updated!
    raise ArgumentError, 'Set service_amount before adding payment' if appointment.service_amount.to_i <= 0
    raise ArgumentError, 'Cancelled payments cannot be updated' if appointment.payment_status == 'cancelled'
  end

  def resolve_payment_amount(amount)
    already_received = appointment.prepaid_amount.to_i + appointment.settlement_amount.to_i
    remaining = [appointment.service_amount.to_i - already_received, 0].max
    payment_amount = amount.present? ? Scheduling::IntegerNumericNormalizer.normalize(amount, field_name: 'amount') : remaining

    raise ArgumentError, 'Payment amount must be greater than 0' unless payment_amount.positive?
    raise ArgumentError, 'Payment amount exceeds remaining balance' if already_received + payment_amount > appointment.service_amount.to_i

    payment_amount
  end

  def compute_expense_amount
    return 0 if appointment.compensation_type_snapshot.blank?
    return appointment.compensation_value_snapshot.to_i if appointment.compensation_type_snapshot == 'fixed'
    return appointment.compensation_value_snapshot.to_i + percentage_expense_amount if appointment.compensation_type_snapshot == 'fixed_plus_percent'

    ((appointment.service_amount.to_i * appointment.compensation_value_snapshot.to_i) / 100.0).round
  end

  def percentage_expense_amount
    ((appointment.service_amount.to_i * appointment.compensation_percent_snapshot.to_i) / 100.0).round
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
    return remove_unpaid_expense!(existing_expense) unless appointment_paid?

    upsert_expense!(existing_expense)
  end

  def upsert_payment_by_kind(kind, amount, payment_method)
    payment = appointment.payments.find_by(payment_kind: kind)
    normalized_amount = Scheduling::IntegerNumericNormalizer.normalize_or_zero(amount, field_name: "#{kind}_amount")

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

  def appointment_paid?
    appointment.payment_status == 'paid'
  end

  def remove_unpaid_expense!(existing_expense)
    existing_expense.destroy! if existing_expense.present? && existing_expense.status != 'paid'
    existing_expense
  end

  def upsert_expense!(existing_expense)
    return existing_expense if existing_expense.present? && existing_expense.status == 'paid'
    return update_existing_expense!(existing_expense) if existing_expense.present?

    appointment.create_expense!(
      account: appointment.account,
      resource: appointment.resource,
      amount: compute_expense_amount,
      status: 'unpaid'
    )
  end

  def update_existing_expense!(existing_expense)
    existing_expense.update!(
      resource: appointment.resource,
      amount: compute_expense_amount,
      status: 'unpaid'
    )
    existing_expense
  end
end
