class Integrations::Medelement::AppointmentSnapshotGuard
  LOCAL_CANCELLATION_ATTRIBUTE = 'medelement_local_cancelled_at'.freeze
  StaleSnapshotError = Class.new(StandardError)

  def initialize(appointment:, snapshot_version:, reception_code:)
    @appointment = appointment
    @snapshot_version = snapshot_version
    @reception_code = reception_code.to_s
  end

  def validate!
    raise StaleSnapshotError, 'Medelement snapshot conflicts with a pending or confirmed provider removal' if protected_removal?

    return if snapshot_version.blank?
    return if unchanged_since_snapshot?

    raise StaleSnapshotError, 'Medelement snapshot predates a newer local appointment mutation'
  end

  private

  attr_reader :appointment, :reception_code, :snapshot_version

  def protected_removal?
    return false unless appointment.persisted? && appointment.status == 'cancelled' && reception_code.present?
    return true if appointment.custom_attributes.to_h[LOCAL_CANCELLATION_ATTRIBUTE].present?

    Integrations::Medelement::ProviderCommand.exists?(
      account_id: appointment.account_id,
      appointment_id: appointment.id,
      operation: 'remove_reception',
      provider_reception_code: reception_code,
      status: protective_removal_statuses
    )
  end

  def protective_removal_statuses
    ['succeeded', *Integrations::Medelement::ProviderCommand::UNFINISHED_STATUSES]
  end

  def unchanged_since_snapshot?
    existed_at_snapshot = snapshot_version.fetch(:exists)
    return !existed_at_snapshot unless appointment.persisted?

    existed_at_snapshot && appointment.updated_at == snapshot_version.fetch(:updated_at)
  end
end
