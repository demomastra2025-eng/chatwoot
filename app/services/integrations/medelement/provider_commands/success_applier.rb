class Integrations::Medelement::ProviderCommands::SuccessApplier
  def initialize(command:, reconciliation_claim_token: nil)
    @command = command
    @reconciliation_claim_token = reconciliation_claim_token
  end

  def patient!(patient_code:)
    with_owned_command do
      link_contact_patient_ref!(patient_code)
      apply_contact_field_resolution!
      complete_command!(provider_patient_code: patient_code)
    end
  end

  def patient_resolved_for_reception!(patient_code:)
    with_owned_command do
      command.update!(
        status: command.status_for_transition('queued'),
        provider_patient_code: patient_code,
        last_error_code: nil,
        last_error_status: nil,
        execution_state: released_reconciliation_state
      )
    end
  end

  def reception_created!(reception_code:, patient_code:)
    with_owned_command do
      appointment.update!(
        starts_at: snapshot_time('destination_starts_at'),
        ends_at: snapshot_time('destination_ends_at'),
        external_ref: "medelement:reception:#{reception_code}",
        custom_attributes: appointment.custom_attributes.to_h.except('medelement_patient_code').merge(
          'medelement_reception_code' => reception_code,
          'medelement_cabinet_code' => command.request_snapshot.fetch('company_cabinet_code'),
          'medelement_provider_sync_status' => 'succeeded'
        ).merge(local_service_binding_attributes)
      )
      link_contact_patient_ref!(patient_code)
      complete_command!(provider_reception_code: reception_code, provider_patient_code: patient_code)
    end
  end

  def reception_moved!
    with_owned_command do
      appointment.update!(
        starts_at: snapshot_time('destination_starts_at'),
        ends_at: snapshot_time('destination_ends_at'),
        custom_attributes: appointment.custom_attributes.to_h.merge(
          'medelement_cabinet_code' => command.request_snapshot.fetch('company_cabinet_code'),
          'medelement_provider_sync_status' => 'succeeded'
        )
      )
      complete_command!
    end
  end

  def reception_removed!
    with_owned_command do
      appointment.update!(
        status: 'cancelled',
        payment_status: 'cancelled',
        custom_attributes: appointment.custom_attributes.to_h.merge('medelement_provider_sync_status' => 'succeeded')
      )
      complete_command!
    end
  end

  private

  attr_reader :command, :reconciliation_claim_token

  def with_owned_command
    command.with_lock do
      command.reload
      next false unless command.processing?
      next false unless reconciliation_claim_owned?

      yield
      true
    end
  end

  def reconciliation_claim_owned?
    return true if reconciliation_claim_token.blank?

    command.execution_state.to_h[
      Integrations::Medelement::ProviderCommands::ReconciliationLifecycle::CLAIM_TOKEN_KEY
    ] == reconciliation_claim_token
  end

  def appointment
    command.appointment
  end

  def snapshot_time(key)
    Time.iso8601(command.request_snapshot.fetch('reception').fetch(key))
  end

  def link_contact_patient_ref!(patient_code)
    return if command.contact.blank?

    ensure_patient_ref_available!(patient_code)
    command.contact.skip_runtime_events = true
    command.contact.update!(custom_attributes: linked_contact_attributes(patient_code))
  end

  def local_service_binding_attributes
    codes = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.service_codes(command.request_snapshot)
    return {} if codes.blank?

    Integrations::Medelement::AppointmentServiceBinding.new(appointment: appointment).local_only_attributes(codes)
  end

  def ensure_patient_ref_available!(patient_code)
    linked_contact = command.account.contacts.find_by(
      "custom_attributes ->> 'medelement_patient_code' = ?",
      patient_code.to_s
    )
    return if linked_contact.blank? || linked_contact.id == command.contact_id

    raise Integrations::Medelement::ProviderCommands::ExecutionError.new(
      code: 'patient_ref_conflict',
      message: 'Medelement patient identity requires reconciliation',
      reconciliation: true
    )
  end

  def linked_contact_attributes(patient_code)
    command.contact.custom_attributes.to_h.merge(
      'medelement_patient_code' => patient_code.to_s,
      'medelement_patient_match_status' => 'matched',
      'medelement_last_synced_at' => Time.current.iso8601
    )
  end

  def apply_contact_field_resolution!
    return if command.execution_state.to_h['contact_field_resolution'].blank?

    Integrations::Medelement::ContactFieldResolutionService.apply_provider_command!(command)
  end

  def released_reconciliation_state
    command.execution_state.to_h.except(
      Integrations::Medelement::ProviderCommands::ReconciliationLifecycle::CLAIM_TOKEN_KEY,
      Integrations::Medelement::ProviderCommands::ReconciliationLifecycle::CLAIMED_AT_KEY,
      'reconciliation_next_at'
    )
  end

  def complete_command!(attributes = {})
    command.update!(
      attributes.merge(
        status: 'succeeded',
        executed_at: Time.current,
        last_error_code: nil,
        last_error_status: nil,
        execution_state: released_reconciliation_state.merge('result' => 'applied')
      )
    )
  end
end
