class Integrations::Medelement::LinkedContactsSyncService
  PATIENT_CODE_KEY = 'medelement_patient_code'.freeze

  def initialize(account:, client:, conflict_tracker: nil, organization_id: nil)
    @account = account
    @client = client
    @conflict_tracker = conflict_tracker
    @resolver = Integrations::Medelement::ContactResolverService.new(
      account: account,
      client: client,
      conflict_tracker: conflict_tracker,
      organization_id: organization_id
    )
  end

  def perform
    result = { linked_count: linked_contacts.count, synced_count: 0, skipped_count: 0 }

    linked_contacts.find_each(batch_size: 100) do |contact|
      sync_contact(contact, result)
    end

    result
  end

  private

  attr_reader :account, :client, :conflict_tracker, :resolver

  def linked_contacts
    account.contacts.where("custom_attributes ->> '#{PATIENT_CODE_KEY}' IS NOT NULL")
  end

  def sync_contact(contact, result)
    patient_code = contact.custom_attributes[PATIENT_CODE_KEY].to_s
    synced_contact = resolver.sync_patient!(patient_code, preferred_contact: contact)
    return result[:synced_count] += 1 if synced_contact

    record_patient_not_found(contact, patient_code, result, 'Provider returned no patient')
  rescue Integrations::Medelement::Client::ApiError => e
    raise unless patient_missing_from_allowed_scope?(patient_code, e)

    reason = e.status == 403 ? 'Provider denied linked patient and code search returned no patient' : 'Provider patient was not found'
    record_patient_not_found(contact, patient_code, result, reason)
  rescue ActiveRecord::RecordInvalid, Scheduling::Error => e
    record_update_rejected(contact, patient_code, result, e)
  end

  def record_patient_not_found(contact, patient_code, result, reason)
    result[:skipped_count] += 1
    record_conflict(contact, patient_code, 'patient_not_found', reason: reason)
  end

  def patient_missing_from_allowed_scope?(patient_code, error)
    return true if error.status == 404
    return false unless error.status == 403
    return false if patient_code.blank?

    patients = client.search_patients_by_codes(patient_codes: [patient_code])
    patients.none? do |patient|
      codes = patient.to_h.with_indifferent_access.values_at(:PROFILE_CODE, :PATIENT_CODE).compact.map(&:to_s)
      codes.include?(patient_code)
    end
  rescue Integrations::Medelement::Client::ApiError
    raise error
  end

  def record_update_rejected(contact, patient_code, result, error)
    result[:skipped_count] += 1
    record_conflict(
      contact,
      patient_code,
      'patient_update_rejected',
      severity: 'error',
      reason: error.class.name
    )
  end

  def record_conflict(contact, patient_code, conflict_type, severity: 'warning', **details)
    conflict_tracker&.record!(
      phase: 'contacts',
      entity_type: 'contact',
      conflict_type: conflict_type,
      entity_key: patient_code.presence || "contact:#{contact.id}",
      severity: severity,
      details: details.merge(contact_id: contact.id)
    )
  end
end
