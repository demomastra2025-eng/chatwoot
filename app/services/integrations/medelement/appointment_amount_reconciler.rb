class Integrations::Medelement::AppointmentAmountReconciler
  def initialize(appointment:, reception:, resource:, services:, conflict_tracker: nil)
    @appointment = appointment
    @reception = reception
    @resource = resource
    @services = services
    @conflict_tracker = conflict_tracker
  end

  def attributes
    if appointment.persisted?
      record_amount_conflict if provider_amount && appointment.service_amount.to_i != provider_amount
      return { service_amount: appointment.service_amount }
    end

    { service_amount: provider_amount || catalog_amount }
  end

  private

  attr_reader :appointment, :conflict_tracker, :reception, :resource, :services

  def catalog_amount
    services.sum do |service|
      price = service.prices.find_by(resource_id: resource.id)
      price&.active? && price.price.to_i.positive? ? price.price.to_i : service.base_price.to_i
    end
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

  def provider_amount
    return @provider_amount if defined?(@provider_amount)

    rows = Integrations::Medelement::ReceptionServiceRows.active(reception)
    amounts = rows.map { |row| provider_row_amount(row) }
    @provider_amount = amounts.sum.round(0, half: :up).to_i if rows.present? && amounts.none?(&:nil?)
  end

  def provider_row_amount(row)
    explicit_total = decimal_value(row['TOTAL_SUM']) || decimal_value(row['SUMMA'])
    return explicit_total if explicit_total

    price = decimal_value(row['PRICE'])
    price * (decimal_value(row['QUANTITY']) || 1) if price
  end

  def decimal_value(value)
    return if value.blank?

    BigDecimal(value.to_s, exception: false)
  end
end
