class Integrations::Medelement::PatientEnrichmentService
  FRESHNESS_WINDOW = 24.hours
  MATCH_STATUSES = %w[matched not_found ambiguous conflict].freeze

  def initialize(hook:, client: nil)
    @hook = hook
    @client = client || Integrations::Medelement::Client.new(
      configuration: Integrations::Medelement::Configuration.new(hook: hook)
    )
  end

  def perform(contact)
    ensure_contact_scope!(contact)
    phone = Integrations::Medelement::PhoneNumber.new(contact.phone_number)
    return contact if lookup_fresh?(contact, phone)

    patients = client.search_patients_by_phone(phone_number: phone.e164)
    return mark!(contact, phone, 'not_found') if patients.empty?
    return mark!(contact, phone, 'ambiguous') unless patients.one?

    patient_code = patients.first['PROFILE_CODE'].presence || patients.first['PATIENT_CODE'].presence
    return mark!(contact, phone, 'ambiguous') if patient_code.blank?
    return mark!(contact, phone, 'conflict') if patient_linked_to_another_contact?(contact, patient_code)

    resolver.sync_patient!(patient_code, preferred_contact: contact)
    mark!(contact.reload, phone, 'matched')
  end

  private

  attr_reader :hook, :client

  def resolver
    @resolver ||= Integrations::Medelement::ContactResolverService.new(
      account: hook.account,
      client: client,
      organization_id: Integrations::Medelement::Configuration.new(hook: hook).organization_id
    )
  end

  def ensure_contact_scope!(contact)
    raise ArgumentError, 'contact must belong to the integration account' unless contact.account_id == hook.account_id
  end

  def patient_linked_to_another_contact?(contact, patient_code)
    hook.account.contacts
        .where("custom_attributes ->> 'medelement_patient_code' = ?", patient_code.to_s)
        .where.not(id: contact.id)
        .exists?
  end

  def lookup_fresh?(contact, phone)
    attributes = contact.custom_attributes.to_h
    return false unless attributes['medelement_patient_phone_fingerprint'] == fingerprint(phone)

    Time.zone.parse(attributes['medelement_patient_lookup_at'].to_s) >= FRESHNESS_WINDOW.ago
  rescue ArgumentError, TypeError
    false
  end

  def mark!(contact, phone, status)
    raise ArgumentError, 'unsupported match status' unless MATCH_STATUSES.include?(status)

    contact.skip_runtime_events = true
    contact.custom_attributes = contact.custom_attributes.to_h.merge(
      'medelement_patient_lookup_at' => Time.current.iso8601,
      'medelement_patient_match_status' => status,
      'medelement_patient_phone_fingerprint' => fingerprint(phone)
    )
    contact.save!
    contact
  end

  def fingerprint(phone)
    Digest::SHA256.hexdigest(phone.e164)
  end
end
