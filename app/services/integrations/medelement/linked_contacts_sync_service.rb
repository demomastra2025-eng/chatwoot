class Integrations::Medelement::LinkedContactsSyncService
  PATIENT_CODE_KEY = 'medelement_patient_code'.freeze
  BATCH_CURSOR_KEY = 'medelement_batch_considered_at'.freeze
  BATCH_SIZE = 100

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
    linked_count = linked_contacts.count
    contacts = linked_contacts
               .order(Arel.sql("NULLIF(custom_attributes ->> '#{BATCH_CURSOR_KEY}', '') ASC NULLS FIRST, id ASC"))
               .limit(BATCH_SIZE)
    selected_count = contacts.size
    result = {
      linked_count: linked_count,
      selected_count: selected_count,
      deferred_count: linked_count - selected_count,
      synced_count: 0,
      skipped_count: 0
    }

    processed_entity_keys = contacts.map { |contact| process_contact(contact, result) }
    resolve_processed_conflicts!(processed_entity_keys)

    result
  end

  private

  attr_reader :account, :client, :conflict_tracker, :resolver

  def process_contact(contact, result)
    entity_key = conflict_entity_key(contact)
    sync_contact(contact, result)
    mark_batch_considered!(contact)
    entity_key
  end

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

  def mark_batch_considered!(contact)
    contact.with_lock do
      contact.reload
      attributes = contact.custom_attributes.merge(BATCH_CURSOR_KEY => Time.current.iso8601)
      # This isolated scheduler cursor must advance even when legacy contact validations are not repairable by this sync.
      # rubocop:disable Rails/SkipsModelValidations
      contact.update_column(:custom_attributes, attributes)
      # rubocop:enable Rails/SkipsModelValidations
    end
  end

  def conflict_entity_key(contact)
    contact.custom_attributes[PATIENT_CODE_KEY].to_s.presence || "contact:#{contact.id}"
  end

  def resolve_processed_conflicts!(entity_keys)
    conflict_tracker&.resolve_absent!('contacts', entity_keys: entity_keys)
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
