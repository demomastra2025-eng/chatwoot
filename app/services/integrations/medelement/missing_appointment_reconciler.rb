class Integrations::Medelement::MissingAppointmentReconciler
  MISSING_CONFIRMATIONS_REQUIRED = 2

  def initialize(appointment:)
    @appointment = appointment
  end

  def perform
    appointment.with_lock { reconcile! }
  end

  private

  attr_reader :appointment

  def reconcile!
    attributes = missing_attributes
    missing_confirmed?(attributes) ? tombstone!(attributes) : appointment.custom_attributes = attributes
    appointment.save! if appointment.changed?
  end

  def missing_attributes
    attributes = appointment.custom_attributes.to_h.deep_stringify_keys
    attributes['medelement_missing_since'] ||= Time.current.iso8601
    attributes['medelement_missing_syncs'] = attributes['medelement_missing_syncs'].to_i + 1
    attributes
  end

  def missing_confirmed?(attributes)
    attributes['medelement_missing_syncs'] >= MISSING_CONFIRMATIONS_REQUIRED
  end

  def tombstone!(attributes)
    attributes['medelement_removed_at'] ||= Time.current.iso8601
    attributes['source_mode'] = 'provider_tombstone'
    appointment.assign_attributes(
      status: 'cancelled',
      payment_status: 'cancelled',
      custom_attributes: attributes
    )
  end
end
