class Integrations::Medelement::LinkedContactsSyncService
  PATIENT_CODE_KEY = 'medelement_patient_code'.freeze

  def initialize(account:, client:, conflict_tracker: nil)
    @account = account
    @client = client
    @conflict_tracker = conflict_tracker
    @resolver = Integrations::Medelement::ContactResolverService.new(
      account: account,
      client: client,
      conflict_tracker: conflict_tracker
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
    raise unless e.status == 404

    record_patient_not_found(contact, patient_code, result, 'Provider patient was not found')
  rescue ActiveRecord::RecordInvalid, Scheduling::Error => e
    record_update_rejected(contact, patient_code, result, e)
  end

  def record_patient_not_found(contact, patient_code, result, reason)
    result[:skipped_count] += 1
    record_conflict(contact, patient_code, 'patient_not_found', reason: reason)
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
