module Integrations::Medelement::AppointmentPatientBindingSnapshot
  IN_FLIGHT_STATUSES = %w[processing reconciliation_required provider_status_unknown].freeze

  module_function

  # Unfinished commands whose provider write has started or awaits verification; their captured patient binding must
  # stay until they settle. Queued commands that have not written yet are fenced by current? at their write phase.
  def writes_in_flight(appointment_ids)
    command_class = Integrations::Medelement::ProviderCommand
    commands = command_class.unfinished.where(appointment_id: appointment_ids)
    statuses = IN_FLIGHT_STATUSES.flat_map { |status| command_class.execution_statuses(status) }
    commands.where("NULLIF(execution_state ->> 'write_phase', '') IS NOT NULL").or(commands.where(status: statuses))
  end

  def current?(command, appointment: command.appointment)
    captured = command.request_snapshot[Integrations::Medelement::AppointmentPatientIdentity::BINDING_KEY]
    return captured.nil? unless appointment
    return captured_card_match?(command, appointment, captured) if captured
    return true if appointment.patient_contact_id.nil?

    completed_card_match?(command, appointment)
  end

  def captured_card_match?(command, appointment, captured)
    return false unless captured == appointment.patient_contact_id
    return false unless appointment.patient_contact&.account_id == appointment.account_id
    return false unless patient_phone_current?(command, appointment)

    provider_reference_current?(command, appointment)
  end

  def provider_reference_current?(command, appointment)
    codes = live_provider_codes(appointment)
    expected = command.request_snapshot['provider_patient_code'].presence || command.provider_patient_code.presence
    codes.size <= 1 && (expected.blank? || codes.empty? || codes == [expected.to_s])
  end

  def patient_phone_current?(command, appointment)
    return true if command.succeeded? || !Integrations::Medelement::AppointmentPatientIdentity.owned?(appointment.custom_attributes)

    phones = command.request_snapshot['patient_phone_numbers'].presence || command.request_snapshot.dig('patient', 'phone_numbers')
    return true unless phones

    expected = Integrations::Medelement::PatientContactBinding.provider_phone(appointment, authored_phone: appointment.client_phone)
    phones.filter_map { |phone| Integrations::Medelement::PhoneNumber.normalize(phone) }.uniq == [expected]
  rescue Scheduling::Error
    false
  end

  def live_provider_codes(appointment)
    [appointment.custom_attributes.to_h['medelement_patient_code'],
     appointment.patient_contact&.custom_attributes.to_h['medelement_patient_code']].filter_map { |code| code.to_s.presence }.uniq
  end

  def completed_card_match?(command, appointment)
    policy = Integrations::Medelement::AppointmentPatientIdentity
    return false unless command.succeeded? && policy.frozen?(command.request_snapshot)
    return false unless command.request_snapshot[policy::SNAPSHOT_KEY] == policy.current_snapshot(appointment)

    expected = command.provider_patient_code.presence || command.request_snapshot['provider_patient_code'].presence
    expected.present? && captured_card_match?(command, appointment, appointment.patient_contact_id) &&
      same_provider_card?(appointment.patient_contact, appointment.account_id, expected)
  end

  def same_provider_card?(card, account_id, expected)
    card.present? && card.account_id == account_id && card.custom_attributes.to_h['medelement_patient_code'].to_s == expected.to_s
  end
end
