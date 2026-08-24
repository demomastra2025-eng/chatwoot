class Integrations::Medelement::MissingAppointmentReconciler
  MISSING_CONFIRMATIONS_REQUIRED = 2

  def initialize(appointment:, snapshot_version:)
    @appointment = appointment
    @snapshot_version = snapshot_version
  end

  def perform
    appointment.with_lock { snapshot_current? ? reconcile! : :stale_snapshot }
  end

  private

  attr_reader :appointment, :snapshot_version

  def snapshot_current?
    snapshot_version.present? && appointment.updated_at == snapshot_version
  end

  def reconcile!
    attributes = missing_attributes
    missing_confirmed?(attributes) ? tombstone!(attributes) : appointment.custom_attributes = attributes
    return unless appointment.changed?

    appointment.mark_medelement_provider_reconciled!
    appointment.save!
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
