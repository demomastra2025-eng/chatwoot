# rubocop:disable Metrics/ClassLength
class Integrations::Medelement::AppointmentImporterService
  MEDELEMENT_SOURCE = 'medelement'.freeze
  RECEPTION_EXTERNAL_REF_PREFIX = 'medelement:reception:'.freeze
  PRIMARY_APPOINTMENT_TYPE = 'primary'.freeze
  NO_SHOW_PROVIDER_STATUSES = ['no_show', 'no show', 'неявка', 'не явился', 'не явилась'].freeze
  CANCELLED_PROVIDER_STATUSES = %w[cancelled canceled отменена отменено].freeze
  COMPLETED_PROVIDER_STATUSES = %w[completed complete завершена завершено оказана].freeze
  RECONCILIATION_ATTRIBUTE_KEYS = %w[
    medelement_missing_since
    medelement_missing_syncs
    medelement_removed_at
    medelement_detail_retry_at
  ].freeze
  ImportSubject = Data.define(:patient_contact, :contact, :preserve_identity)

  def initialize(account:, conflict_tracker: nil)
    @account = account
    @conflict_tracker = conflict_tracker
  end

  def external_ref_for(reception_code)
    "#{RECEPTION_EXTERNAL_REF_PREFIX}#{reception_code}"
  end

  def upsert!(resource:, contact:, reception:, import_context:)
    appointment, late_materialization = find_or_initialize_appointment(
      reception,
      resource: resource,
      import_context: import_context
    )
    import_context = import_context.except(:snapshot_version) if late_materialization
    contact = appointment.contact if late_materialization
    unless appointment.persisted?
      return persist_appointment!(
        appointment,
        resource: resource,
        contact: contact,
        reception: reception,
        import_context: import_context
      )
    end

    appointment.with_lock do
      persist_appointment!(appointment, resource: resource, contact: contact, reception: reception, import_context: import_context)
    end
  end

  private

  attr_reader :account, :conflict_tracker

  def persist_appointment!(appointment, resource:, contact:, reception:, import_context:)
    Integrations::Medelement::AppointmentSnapshotGuard.new(
      appointment: appointment,
      snapshot_version: import_context[:snapshot_version], reception_code: reception['RECEPTION_CODE']
    ).validate!
    provider_binding(appointment, reception).validate!
    subject = import_subject(appointment, contact, reception)
    contact = subject.contact
    record_unresolved_patient_conflict(reception) if contact.blank?
    attributes = appointment_attributes(
      appointment: appointment,
      resource: resource,
      contact: contact,
      reception: reception,
      import_context: import_context
    )
    restore_paid_local_cancellation_expense = restore_paid_local_cancellation_expense?(appointment, attributes)
    appointment.assign_attributes(attributes)
    assign_import_subject!(appointment, subject)
    persist_imported_appointment!(appointment, restore_paid_local_cancellation_expense)
    appointment
  end

  def persist_imported_appointment!(appointment, restore_paid_local_cancellation_expense)
    ApplicationRecord.transaction do
      appointment.save! if appointment.new_record? || appointment.changed?
      sync_restored_local_cancellation_expense!(appointment) if restore_paid_local_cancellation_expense
    end
  end

  def restore_paid_local_cancellation_expense?(appointment, attributes)
    local_cancellation.marked?(appointment) && appointment.payment_status == 'cancelled' &&
      attributes[:status] != 'cancelled' && attributes[:payment_status] == 'paid'
  end

  def sync_restored_local_cancellation_expense!(appointment)
    Scheduling::Appointments::FinanceSyncService.new(appointment: appointment).sync_expense_only!
  end

  def import_subject(appointment, contact, reception)
    return preserved_import_subject(appointment, reception) if preserve_local_patient_identity?(appointment)

    if appointment.patient_contact_id.present?
      # Same patient, possibly re-coded by MedElement onto the same card: keep the binding and the appointment chat contact.
      if local_patient_reference?(appointment, reception) || contact&.id == appointment.patient_contact_id
        return ImportSubject.new(patient_contact: appointment.patient_contact, contact: appointment.contact, preserve_identity: false)
      end

      release_provider_patient_binding!(appointment, reception, contact)
    end
    delivery_contact = Integrations::Medelement::PatientContactBinding.delivery_contact(contact)
    ImportSubject.new(patient_contact: contact, contact: delivery_contact, preserve_identity: false)
  end

  # Locally authored appointments keep their recorded patient: the reference is checked before any card lookup or contact write.
  def preserved_import_subject(appointment, reception)
    validate_local_patient_reference!(appointment, reception)
    Integrations::Medelement::PatientContactBinding.new(appointment: appointment).prepare!(patient_code: reception['PATIENT_CODE'])
    record_patient_card_repair_conflict(appointment, reception)
    ImportSubject.new(patient_contact: appointment.patient_contact || appointment.contact, contact: appointment.contact, preserve_identity: true)
  end

  # MedElement owns the patient of its own receptions. A provider-side patient change re-resolves the subject like a
  # fresh import (the appointment chat contact stays when the new patient still shares it; touches pick their route
  # at send time, see Reminders::PatientSubjectGuard). Only a local provider write that has
  # started or awaits verification keeps the captured binding until it settles.
  def release_provider_patient_binding!(appointment, reception, contact)
    if Integrations::Medelement::AppointmentPatientBindingSnapshot.writes_in_flight(appointment.id).exists?
      raise Scheduling::Error.new(
        code: 'MEDELEMENT_BOOKING_REQUIRES_VERIFICATION', message: 'Patient identity is locked while a provider write requires verification',
        status: :conflict
      )
    end

    record_provider_patient_change_conflict(appointment, reception, contact)
    appointment.patient_contact = nil
    appointment.custom_attributes = appointment.custom_attributes.except(
      Integrations::Medelement::AppointmentPatientIdentity::OWNED_IDENTITY_KEY, 'medelement_patient_code'
    )
  end

  def assign_import_subject!(appointment, subject)
    patient = subject.patient_contact
    appointment.assign_attributes(client_attributes(patient)) unless subject.preserve_identity
    return unless patient && patient.id != subject.contact&.id

    appointment.patient_contact = patient
    appointment.custom_attributes = appointment.custom_attributes.merge(
      Integrations::Medelement::AppointmentPatientIdentity::OWNED_IDENTITY_KEY => true,
      'medelement_patient_code' => patient.custom_attributes['medelement_patient_code']
    ).compact
  end

  # Keep the provider-to-appointment mapping visible as one declarative contract.
  # rubocop:disable Metrics/MethodLength
  def appointment_attributes(appointment:, resource:, contact:, reception:, import_context:)
    starts_at, ends_at = import_context.values_at(:starts_at, :ends_at)
    services, unresolved_service_codes = resolved_services(reception)
    service_binding = Integrations::Medelement::AppointmentServiceBinding.new(appointment: appointment)
    service_identity_authoritative = service_binding.provider_identity_authoritative?(reception)
    status_resolution = provider_status_resolution(appointment, reception, starts_at)

    base_attributes = {
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation_for_contact(appointment, contact),
      starts_at: starts_at,
      ends_at: ends_at,
      duration_min: duration_minutes(starts_at, ends_at),
      status: status_resolution[:status],
      appointment_type: PRIMARY_APPOINTMENT_TYPE,
      source: provider_binding(appointment, reception).source,
      service: service_identity_authoritative ? services.first : appointment.service,
      service_name_snapshot: service_identity_authoritative ? services.map(&:name).join(', ').presence : appointment.service_name_snapshot,
      custom_attributes: custom_attributes(
        appointment,
        reception,
        import_context,
        contact: contact,
        services: services,
        unresolved_service_codes: unresolved_service_codes,
        service_binding: service_binding,
        status_resolution: status_resolution
      )
    }

    identity_attributes = preserve_local_patient_identity?(appointment) ? {} : client_attributes(contact)
    merge_appointment_attribute_layers(
      base_attributes: base_attributes,
      identity_attributes: identity_attributes,
      appointment: appointment,
      reception: reception,
      status_resolution: status_resolution
    )
  end

  def merge_appointment_attribute_layers(base_attributes:, identity_attributes:, appointment:, reception:,
                                         status_resolution:)
    base_attributes.merge(identity_attributes)
                   .merge(financial_attributes(appointment, reception))
                   .merge(local_cancellation_payment_attributes(appointment, status_resolution))
  end
  # rubocop:enable Metrics/MethodLength

  # MedElement re-booked or completed a reception that OneLink cancelled only locally: the local
  # cancellation no longer applies, so the payment status it cancelled comes back.
  def local_cancellation_payment_attributes(appointment, status_resolution)
    return {} unless appointment.persisted? && local_cancellation.marked?(appointment)
    return {} if status_resolution[:status] == 'cancelled' || appointment.payment_status != 'cancelled'

    { payment_status: local_cancellation.restored_payment_status(appointment) }
  end

  def local_cancellation
    Integrations::Medelement::LocalCancellation
  end

  def preserve_local_patient_identity?(appointment)
    policy = Integrations::Medelement::AppointmentPatientIdentity
    appointment.persisted? && appointment.source != MEDELEMENT_SOURCE &&
      (policy.owned?(appointment.custom_attributes) || policy.explicit_identifier?(appointment.custom_attributes))
  end

  def validate_local_patient_reference!(appointment, reception)
    return if local_patient_reference?(appointment, reception)

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_PATIENT_IDENTITY_CONFLICT', message: 'Imported reception belongs to another patient', status: :conflict
    )
  end

  def local_patient_reference?(appointment, reception)
    expected = Integrations::Medelement::AppointmentPatientIdentity.provider_code(appointment: appointment, contact: appointment.contact)
    actual = [reception['PATIENT_CODE'], reception['PROFILE_CODE']].filter_map { |value| value.to_s.presence }.uniq
    expected.present? && actual == [expected.to_s]
  end

  # Precedence: an explicit MedElement outcome (no-show, cancelled, completed, removed, inactive) wins over
  # any local status; a local-only cancellation survives while the reception stays active at the same time.
  def provider_status_resolution(appointment, reception, provider_starts_at)
    provider_status = provider_status_value(reception)
    return { status: 'no_show', reason: 'provider_explicit_no_show', raw_status: provider_status } if provider_status.in?(NO_SHOW_PROVIDER_STATUSES)
    if provider_status.in?(CANCELLED_PROVIDER_STATUSES)
      return { status: 'cancelled', reason: 'provider_explicit_cancelled', raw_status: provider_status }
    end
    if provider_status.in?(COMPLETED_PROVIDER_STATUSES)
      return { status: 'completed', reason: 'provider_explicit_completed', raw_status: provider_status }
    end
    return { status: 'cancelled', reason: 'provider_removed' } if reception['REMOVED'].to_i == 1
    return { status: 'completed', reason: 'provider_inactive' } unless reception['ACTIVE'].to_i == 1

    local_cancellation_resolution(appointment, provider_starts_at) || active_reception_resolution(appointment)
  end

  def local_cancellation_resolution(appointment, provider_starts_at)
    return unless appointment.persisted? && appointment.status == 'cancelled' && local_cancellation.marked?(appointment)
    return { status: 'scheduled', reason: local_cancellation::REBOOKED_REASON } if local_cancellation.rebooked?(appointment, provider_starts_at)

    { status: 'cancelled', reason: local_cancellation::PRESERVED_REASON }
  end

  def active_reception_resolution(appointment)
    return { status: 'confirmed', reason: 'preserved_local_confirmation' } if appointment.status == 'confirmed'

    { status: 'scheduled', reason: 'provider_active' }
  end

  def provider_status_value(reception)
    %w[VISIT_STATUS_NAME RECEPTION_STATUS STATUS].filter_map do |key|
      reception[key].to_s.downcase.squish.presence
    end.first
  end

  def client_attributes(contact)
    {
      client_first_name: contact&.name.presence,
      client_last_name: contact&.last_name.presence,
      client_middle_name: contact&.middle_name.presence,
      client_name: client_name(contact),
      client_phone: contact_phone(contact),
      client_identifier: contact&.identifier.presence || contact&.custom_attributes&.dig('iin'),
      client_birth_date: contact&.custom_attributes&.dig('birth_date'),
      client_gender: contact&.custom_attributes&.dig('gender')
    }
  end

  def financial_attributes(appointment, reception)
    Integrations::Medelement::AppointmentFinancialReconciler.new(
      appointment: appointment,
      reception: reception,
      conflict_tracker: conflict_tracker
    ).attributes
  end

  def client_name(contact)
    [contact&.name, contact&.last_name, contact&.middle_name].compact_blank.join(' ').presence ||
      'Unresolved MedElement patient'
  end

  def contact_phone(contact)
    return contact.phone_number if contact&.phone_number.present?

    owner = Integrations::Medelement::PatientContactBinding.delivery_contact(contact)
    return owner.phone_number if owner && owner.id != contact&.id

    non_conflicting_secondary_phone(contact)
  end

  def non_conflicting_secondary_phone(contact)
    conflict_comment = contact&.custom_attributes&.dig('phone_conflict_comment').to_s
    Array(contact&.custom_attributes&.dig('secondary_phones')).compact_blank.find do |phone|
      conflict_comment.blank? || conflict_comment.exclude?(phone)
    end
  end

  def conversation_for_contact(appointment, contact)
    conversation = appointment.conversation
    return conversation if conversation.blank?
    return conversation if contact.present? && conversation.contact_id == contact.id
  end

  def custom_attributes(appointment, reception, import_context, contact:, **service_data)
    services = service_data.fetch(:services)
    unresolved_service_codes = service_data.fetch(:unresolved_service_codes)
    service_binding = service_data.fetch(:service_binding)
    status_resolution = service_data.fetch(:status_resolution)
    attributes = appointment.custom_attributes.except(*RECONCILIATION_ATTRIBUTE_KEYS).merge(
      'medelement_cabinet_code' => reception['COMPANY_CABINET_CODE'].to_s.presence,
      'medelement_reception_code' => reception['RECEPTION_CODE'].to_s,
      'medelement_source_created_at' => reception['CREATED_AT'].to_s.presence,
      'medelement_specialist_code' => import_context[:specialist_code].to_s,
      'medelement_list_fingerprint' => import_context[:list_fingerprint],
      'medelement_detail_synced_at' => import_context[:detail_synced_at],
      'medelement_patient_unresolved' => contact.blank?,
      'source_mode' => provider_binding(appointment, reception).source_mode,
      'provider_status_audit' => {
        'source' => 'medelement_reception_sync',
        'previous_status' => appointment.status,
        'status' => status_resolution[:status],
        'reason' => status_resolution[:reason],
        'raw_status' => status_resolution[:raw_status],
        'observed_at' => import_context[:detail_synced_at] || Time.current.iso8601
      }.compact
    ).compact
    # The marker lives only while the local cancellation is preserved against an active reception.
    attributes = attributes.except(local_cancellation::MARKER_KEY) unless status_resolution[:reason] == local_cancellation::PRESERVED_REASON
    service_binding.reconcile_provider_attributes(
      attributes: attributes,
      reception: reception,
      services: services,
      unresolved_service_codes: unresolved_service_codes
    )
  end

  def resolved_services(reception)
    codes = reception_service_rows(reception).filter_map do |row|
      row['NOMENCLATURE_CODE'].to_s.presence
    end.uniq
    services_by_code = account.scheduling_services
                              .where("custom_attributes ->> 'medelement_nomenclature_code' IN (?)", codes)
                              .index_by { |service| service.custom_attributes['medelement_nomenclature_code'].to_s }

    [codes.filter_map { |code| services_by_code[code] }, codes.reject { |code| services_by_code.key?(code) }]
  end

  def reception_service_rows(reception) = Integrations::Medelement::ReceptionServiceRows.active(reception)

  def record_unresolved_patient_conflict(reception)
    conflict_tracker&.record!(
      phase: 'receptions',
      entity_type: 'patient',
      conflict_type: 'patient_unresolved',
      entity_key: reception['PATIENT_CODE'].presence || reception['RECEPTION_CODE'],
      severity: 'error',
      details: {
        reason: 'Provider patient could not be linked to a contact',
        reception_code: reception['RECEPTION_CODE'].presence,
        patient_code: reception['PATIENT_CODE'].presence,
        specialist_code: reception['specialistCode'].presence
      }.compact
    )
  end

  def record_patient_card_repair_conflict(appointment, reception)
    return unless Integrations::Medelement::PatientContactBinding.legacy_owner_holds_code?(appointment)

    conflict_tracker&.record!(
      phase: 'receptions',
      entity_type: 'appointment',
      conflict_type: 'patient_card_repair_required',
      entity_key: "appointment:#{appointment.id}",
      details: {
        reason: 'The chat contact holds the patient code of this appointment; review it with the patient card repair task',
        appointment_id: appointment.id,
        contact_id: appointment.contact_id,
        reception_code: reception['RECEPTION_CODE'].presence
      }.compact
    )
  end

  def record_provider_patient_change_conflict(appointment, reception, contact)
    conflict_tracker&.record!(
      phase: 'receptions',
      entity_type: 'appointment',
      conflict_type: 'patient_changed_by_provider',
      entity_key: "appointment:#{appointment.id}",
      details: {
        reason: 'MedElement moved this reception to another patient; the appointment now follows the provider patient',
        appointment_id: appointment.id,
        previous_patient_contact_id: appointment.patient_contact_id,
        new_patient_contact_id: contact&.id,
        reception_code: reception['RECEPTION_CODE'].presence
      }.compact
    )
  end

  def duration_minutes(starts_at, ends_at)
    [((ends_at - starts_at) / 60).round, Scheduling::Constants::MIN_DURATION_MINUTES].max
  end

  def provider_binding(appointment, reception)
    Integrations::Medelement::AppointmentProviderBinding.new(appointment: appointment, reception: reception)
  end

  def find_or_initialize_appointment(reception, resource:, import_context:)
    external_ref = external_ref_for(reception['RECEPTION_CODE'])
    appointment = account.scheduling_appointments.find_or_initialize_by(external_ref: external_ref)
    return [appointment, false] if appointment.persisted?

    pending = Integrations::Medelement::ProviderCommands::PendingReceptionResolver.new(account: account).resolve(
      reception: reception,
      resource: resource,
      import_context: import_context
    )
    return [pending, true] if pending

    [appointment, false]
  end
end
# rubocop:enable Metrics/ClassLength
