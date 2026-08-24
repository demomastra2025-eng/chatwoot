class Integrations::Medelement::AppointmentSnapshotGuard
  StaleSnapshotError = Class.new(StandardError)

  def initialize(appointment:, snapshot_version:)
    @appointment = appointment
    @snapshot_version = snapshot_version
  end

  def validate!
    return if snapshot_version.blank?
    return if unchanged_since_snapshot?

    raise StaleSnapshotError, 'Medelement snapshot predates a newer local appointment mutation'
  end

  private

  attr_reader :appointment, :snapshot_version

  def unchanged_since_snapshot?
    existed_at_snapshot = snapshot_version.fetch(:exists)
    return !existed_at_snapshot unless appointment.persisted?

    existed_at_snapshot && appointment.updated_at == snapshot_version.fetch(:updated_at)
  end
end
