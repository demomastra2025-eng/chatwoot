class Integrations::Medelement::MissingAppointmentReconciler
  MISSING_CONFIRMATIONS_REQUIRED = 2

  def initialize(appointment:, snapshot_version:, provider_removal_confirmed: false)
    @appointment = appointment
    @snapshot_version = snapshot_version
    @provider_removal_confirmed = provider_removal_confirmed
  end

  def perform
    appointment.with_lock { snapshot_current? ? reconcile! : :stale_snapshot }
  end

  private

  attr_reader :appointment, :snapshot_version, :provider_removal_confirmed

  def snapshot_current?
    snapshot_version.present? && appointment.updated_at == snapshot_version
  end

  def reconcile!
    if !provider_removal_confirmed &&
       Integrations::Medelement::ProviderCommands::ReceptionReceiptVerificationService.unmaterialized_current_create?(appointment)
      return :awaiting_provider_materialization
    end

    attributes = missing_attributes
    if provider_removal_confirmed || missing_confirmed?(attributes)
      tombstone!(attributes)
    else
      appointment.custom_attributes = attributes
    end
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
    # The reception is gone from MedElement too, so a local-only cancellation is no longer pending there.
    attributes.delete(Integrations::Medelement::LocalCancellation::MARKER_KEY)
    attributes['provider_status_audit'] = {
      'source' => 'medelement_missing_reconciliation',
      'previous_status' => appointment.status,
      'status' => 'cancelled',
      'reason' => provider_removal_confirmed ? 'provider_removed' : 'missing_from_two_authoritative_snapshots',
      'observed_at' => Time.current.iso8601
    }
    appointment.assign_attributes(
      status: 'cancelled',
      payment_status: 'cancelled',
      custom_attributes: attributes
    )
  end
end
