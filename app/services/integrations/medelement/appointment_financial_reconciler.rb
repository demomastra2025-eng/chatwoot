class Integrations::Medelement::AppointmentFinancialReconciler
  AWAITING_PAYMENT_STATUS = 'awaiting_payment'.freeze

  def initialize(appointment:, reception:, conflict_tracker: nil)
    @appointment = appointment
    @reception = reception
    @conflict_tracker = conflict_tracker
  end

  def attributes
    return new_appointment_attributes unless appointment.persisted?

    record_conflicts
    preserved_attributes
  end

  private

  attr_reader :appointment, :conflict_tracker, :reception

  def new_appointment_attributes
    {
      service_amount: provider_amount || 0,
      prepaid_amount: 0,
      settlement_amount: 0,
      payment_status: AWAITING_PAYMENT_STATUS
    }
  end

  def preserved_attributes
    {
      service_amount: appointment.service_amount,
      prepaid_amount: appointment.prepaid_amount,
      settlement_amount: appointment.settlement_amount,
      payment_status: appointment.payment_status
    }
  end

  def record_conflicts
    record_amount_conflict if provider_amount && appointment.service_amount.to_i != provider_amount
    record_local_payment_conflict if local_payment_present?
  end

  def record_amount_conflict
    conflict_tracker&.record!(
      phase: 'receptions',
      entity_type: 'appointment',
      conflict_type: 'appointment_amount_mismatch',
      entity_key: reception['RECEPTION_CODE'],
      details: {
        reason: 'Provider amount differs from the preserved appointment amount',
        appointment_id: appointment.id,
        reception_code: reception['RECEPTION_CODE'].presence,
        local_amount: appointment.service_amount.to_i,
        provider_amount: provider_amount
      }.compact
    )
  end

  def record_local_payment_conflict
    conflict_tracker&.record!(
      phase: 'receptions',
      entity_type: 'appointment',
      conflict_type: 'local_payment_preserved',
      entity_key: reception['RECEPTION_CODE'],
      details: {
        reason: 'Local payment data was preserved during provider pull',
        appointment_id: appointment.id,
        reception_code: reception['RECEPTION_CODE'].presence
      }.compact
    )
  end

  def local_payment_present?
    appointment.prepaid_amount.to_i.positive? || appointment.settlement_amount.to_i.positive? ||
      appointment.payment_status != AWAITING_PAYMENT_STATUS
  end

  def provider_amount
    return @provider_amount if defined?(@provider_amount)

    rows = reception_service_rows
    amounts = rows.map { |row| provider_row_amount(row) }
    @provider_amount = amounts.sum.round(0, half: :up).to_i if rows.present? && amounts.none?(&:nil?)
  end

  def provider_row_amount(row)
    explicit_total = decimal_value(row['TOTAL_SUM']) || decimal_value(row['SUMMA'])
    return explicit_total if explicit_total

    price = decimal_value(row['PRICE'])
    price * (decimal_value(row['QUANTITY']) || 1) if price
  end

  def reception_service_rows
    Array(reception['SERVICES']).select { |row| row.is_a?(Hash) }
  end

  def decimal_value(value)
    return if value.blank?

    BigDecimal(value.to_s, exception: false)
  end
end
