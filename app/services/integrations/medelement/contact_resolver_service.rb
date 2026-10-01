# rubocop:disable Metrics/ClassLength
class Integrations::Medelement::ContactResolverService
  FRESHNESS_WINDOW = 24.hours
  GENDER_MAP = {
    '1' => 'female',
    '2' => 'male'
  }.freeze

  def initialize(account:, client:, conflict_tracker: nil, organization_id: nil)
    @account = account
    @client = client
    @conflict_tracker = conflict_tracker
    @organization_id = organization_id
  end

  def sync_patient!(patient_code, preferred_contact: nil)
    validate_preferred_contact!(preferred_contact)
    existing_contact = preferred_contact || find_by_patient_code(patient_code)
    return existing_contact if fresh?(existing_contact)

    patient = client.get_patient(patient_code: patient_code)
    return existing_contact if patient.blank?

    validate_patient!(patient, expected_patient_code: patient_code)
    return existing_contact if provider_read_models_conflict?(patient_code, patient, existing_contact)

    upsert_contact(patient, preferred_contact: preferred_contact)
  end

  def sync_patient_payload!(patient, preferred_contact:)
    validate_preferred_contact!(preferred_contact)
    patient_code = patient['PROFILE_CODE'].presence || patient['PATIENT_CODE'].presence
    validate_patient!(
      patient,
      expected_patient_code: preferred_contact.custom_attributes['medelement_patient_code'].presence,
      expected_iin: preferred_contact.custom_attributes['iin'].presence || preferred_contact.identifier,
      expected_phone_numbers: Integrations::Medelement::PhoneNumber.contact_phones(preferred_contact)
    )
    return preferred_contact if patient_code.blank?
    return preferred_contact if provider_read_models_conflict?(patient_code, patient, preferred_contact)

    upsert_contact(patient, preferred_contact: preferred_contact)
  end

  def sync_verified_demographic_candidate!(patient_code, candidate_contact:)
    patient = client.get_patient(patient_code: patient_code)
    return if patient.blank?

    validate_patient!(patient, expected_patient_code: patient_code)
    iin = normalize_iin(patient['IIN'])
    return if iin.blank?

    Integrations::Medelement::ProviderCommands::PatientIdentityLock.new(
      account_id: account.id,
      iin: iin
    ).synchronize do
      resolve_verified_demographic_candidate(patient_code, candidate_contact, patient, iin)
    end
  end

  private

  attr_reader :account, :client, :conflict_tracker, :organization_id

  def validate_preferred_contact!(preferred_contact)
    return if preferred_contact.blank? || preferred_contact.account_id == account.id

    raise ArgumentError, 'preferred contact must belong to the resolver account'
  end

  def resolve_verified_demographic_candidate(patient_code, candidate_contact, patient, iin)
    existing_contact = find_by_patient_code(patient_code)
    return existing_contact if existing_contact
    return if provider_read_models_conflict?(patient_code, patient, nil)

    candidate = find_verified_demographic_candidate(
      patient_code: patient_code,
      iin: iin,
      email: patient['PATIENT_EMAIL'].to_s.downcase.presence,
      patient: patient
    )
    return unless candidate&.id == candidate_contact.id

    upsert_contact(patient, preferred_contact: candidate_contact)
  end

  def validate_patient!(patient, expected_patient_code: nil, expected_iin: nil, expected_phone_numbers: [])
    Integrations::Medelement::ProviderScope.validate_patient!(
      patient,
      organization_id: organization_id,
      expected_patient_code: expected_patient_code,
      expected_iin: expected_iin,
      expected_phone_numbers: expected_phone_numbers
    )
  end

  def contact_for_lookup(patient_code:, iin:, email:, patient:, preferred_contact: nil)
    return preferred_contact if preferred_contact

    linked_contact = find_by_patient_code(patient_code)
    return linked_contact if linked_contact

    iin_contact, identity_known = contact_by_iin(iin, patient_code)
    return iin_contact if identity_known

    find_verified_demographic_candidate(patient_code: patient_code, iin: iin, email: email, patient: patient, automatic: true)
  end

  def contact_by_iin(iin, patient_code)
    contacts = contacts_by_iin(iin)
    return [nil, false] if contacts.empty?

    candidate = contacts.first if contacts.one?
    return [candidate, true] if candidate && patient_code_available_for?(candidate, patient_code) && contact_iin_compatible?(candidate, iin)

    [nil, true]
  end

  # A contact whose IIN only an unauthenticated widget visitor or public API client could have written (no recorded
  # patient identity, an unverified widget/API chat) is never adopted as the patient: the import would give it the
  # patient's code, name, phone and MedElement data, which the widget then shows to that visitor.
  def contacts_by_iin(iin)
    return [] if iin.blank?

    account.contacts
           .where(
             "identifier = :iin OR custom_attributes ->> 'iin' = :iin OR custom_attributes ->> 'medelement_iin' = :iin",
             iin: iin
           )
           .order(:id).limit(10).to_a
           .reject { |contact| Contacts::SharedPhone.self_declared_identity?(contact, iin) }
           .first(2)
  end

  # automatic: the import's own lookup (no staff choice); self-declared public contacts are not candidates there.
  def find_verified_demographic_candidate(patient_code:, iin:, email:, patient:, automatic: false)
    return if iin.blank?

    candidates = demographic_candidates(email: email, phones: provider_phones(patient)).select do |candidate|
      next false if automatic && Contacts::SharedPhone.self_declared_identity?(candidate, iin)

      demographic_match?(candidate, patient_code, iin, patient)
    end
    candidates.one? ? candidates.first : nil
  end

  def demographic_match?(candidate, patient_code, iin, patient)
    patient_code_available_for?(candidate, patient_code) &&
      contact_iin_compatible?(candidate, iin) &&
      contact_name_matches?(candidate, patient) &&
      contact_birth_date_matches?(candidate, patient)
  end

  def demographic_candidates(email:, phones:)
    candidate_ids = account.contacts.where(phone_number: phones).pluck(:id) if phones.present?
    candidate_ids = Array(candidate_ids)
    candidate_ids.concat(account.contacts.where('LOWER(email) = ?', email.downcase).pluck(:id)) if email.present?

    account.contacts.where(id: candidate_ids.uniq).to_a
  end

  def patient_code_available_for?(contact, patient_code)
    linked_code = contact.custom_attributes.to_h['medelement_patient_code'].to_s.presence
    linked_code.blank? || linked_code == patient_code.to_s
  end

  def contact_iin_compatible?(contact, iin)
    contact_iins = [
      contact.identifier,
      contact.custom_attributes.to_h['iin'],
      contact.custom_attributes.to_h['medelement_iin']
    ].filter_map { |value| normalize_iin(value) }.uniq
    contact_iins.empty? || contact_iins == [iin]
  end

  def contact_name_matches?(contact, patient)
    contact_tokens = normalized_name_tokens(contact.name, contact.last_name, contact.middle_name)
    provider_tokens = normalized_name_tokens(
      patient['FULLNAME'],
      patient['LASTNAME'],
      patient_first_name(patient),
      patient['MIDDLENAME']
    )

    contact_tokens.present? && contact_tokens == provider_tokens
  end

  def normalized_name_tokens(*values)
    values.compact_blank
          .flat_map { |value| value.to_s.unicode_normalize(:nfkc).downcase.scan(/[[:alnum:]]+/) }
          .uniq
          .sort
  end

  def contact_birth_date_matches?(contact, patient)
    provider_birth_date = normalize_birth_date(patient['BIRTHDAY'])
    contact_birth_date = normalized_contact_birth_date(contact)
    provider_birth_date.present? && provider_birth_date == contact_birth_date
  end

  def normalized_contact_birth_date(contact)
    value = contact.custom_attributes.to_h['birth_date']
    return if value.blank?

    Date.parse(value.to_s).iso8601
  rescue ArgumentError
    nil
  end

  def find_by_patient_code(patient_code)
    account.contacts.find_by("custom_attributes ->> 'medelement_patient_code' = ?", patient_code.to_s)
  end

  def provider_read_models_conflict?(patient_code, direct_patient, contact)
    Integrations::Medelement::PatientReadModelGuard.new(
      client: client,
      conflict_tracker: conflict_tracker,
      organization_id: organization_id
    ).conflict?(patient_code: patient_code, direct_patient: direct_patient, contact: contact)
  end

  def fresh?(contact)
    synced_at = contact&.custom_attributes&.dig('medelement_last_synced_at')
    return false if synced_at.blank?

    Time.zone.parse(synced_at.to_s) >= FRESHNESS_WINDOW.ago
  rescue ArgumentError, TypeError
    false
  end

  def gender_value(patient)
    GENDER_MAP[patient['GENDER'].to_s] || patient['GENDER_NAME'].to_s.presence || patient['GENDER'].to_s.presence
  end

  def normalize_birth_date(value)
    return if value.blank?

    Date.strptime(value.to_s, '%d.%m.%Y').iso8601
  rescue ArgumentError
    nil
  end

  def normalize_iin(value)
    return if value.blank?

    iin = value.to_s.gsub(/\D/, '')
    iin if Scheduling::IinValidator.valid?(iin)
  end

  def patient_first_name(patient)
    explicit_name = patient['NAME'].presence || patient['FIRSTNAME'].presence
    return explicit_name if explicit_name

    parts = patient['FULLNAME'].to_s.split
    parts.shift if patient['LASTNAME'].present? && parts.first == patient['LASTNAME'].to_s
    parts.pop if patient['MIDDLENAME'].present? && parts.last == patient['MIDDLENAME'].to_s
    parts.join(' ').presence
  end

  def safe_unique_value(contact, attribute, value)
    return if value.blank?

    existing = account.contacts.where(attribute => value).where.not(id: contact.id).first
    return if existing.present?

    value
  end

  def provider_phones(patient)
    Integrations::Medelement::PhoneNumber.patient_phones(patient)
  end

  def secondary_phones(contact, patient, primary_phone)
    existing = Integrations::Medelement::PhoneNumber.contact_phones(contact)
    (existing + provider_phones(patient)).uniq.reject do |phone|
      phone == primary_phone || (primary_phone.present? && account.contacts.where(phone_number: phone).where.not(id: contact.id).exists?)
    end
  end

  # Coordinates identity lookup, uniqueness checks and custom-attribute persistence as one unit.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def upsert_contact(patient, preferred_contact: nil)
    patient_code = patient['PROFILE_CODE'].presence || patient['PATIENT_CODE'].presence
    iin = normalize_iin(patient['IIN'])
    email = patient['PATIENT_EMAIL'].to_s.downcase.presence
    Contact.transaction do
      Contacts::PhoneIdentityLock.acquire!(account_id: account.id)
      linked_contact = find_by_patient_code(patient_code) || linked_preferred_contact(preferred_contact, patient_code)
      identity_contact = contact_for_lookup(
        patient_code: patient_code, iin: iin, email: email, patient: patient, preferred_contact: preferred_contact
      )
      deduplication = Integrations::Medelement::PatientContactDeduplicationService.new(
        account: account,
        patient_code: patient_code,
        provider_phones: provider_phones(patient),
        linked_contact: linked_contact,
        identity_contact: identity_contact
      ).perform
      next preserve_foreign_owner_contact(deduplication.contact, patient_code) if foreign_owner?(deduplication.contact)

      persist_patient_contact!(
        contact: deduplication.contact,
        patient: patient,
        identity: { patient_code: patient_code, iin: iin, email: email },
        phone_conflict_comment: deduplication.phone_conflict_comment
      )
    end
  end

  def linked_preferred_contact(preferred_contact, patient_code)
    linked_code = preferred_contact&.custom_attributes.to_h['medelement_patient_code'].to_s
    preferred_contact if linked_code == patient_code.to_s
  end

  def persist_patient_contact!(contact:, patient:, identity:, phone_conflict_comment:)
    assigned_phone = assignable_provider_phone(contact, patient)
    primary_phone = Integrations::Medelement::PhoneNumber.normalize(assigned_phone.presence || contact.phone_number)

    contact.skip_runtime_events = true
    contact.account ||= account
    first_name = patient_first_name(patient)
    middle_name = patient['MIDDLENAME'].to_s.presence
    contact.name = first_name if first_name.present?
    contact.last_name = patient['LASTNAME'].to_s if contact.respond_to?(:last_name=) && patient['LASTNAME'].present?
    contact.middle_name = middle_name if contact.respond_to?(:middle_name=) && middle_name.present?
    contact.email = safe_unique_value(contact, :email, identity[:email]) || contact.email
    contact.phone_number = safe_unique_value(contact, :phone_number, assigned_phone) || contact.phone_number
    contact.identifier = safe_unique_value(contact, :identifier, identity[:iin]) || contact.identifier
    contact.additional_attributes = (contact.additional_attributes || {}).deep_stringify_keys.reverse_merge(
      'country' => 'Kazakhstan',
      'country_code' => 'KZ'
    )
    contact.custom_attributes = contact.custom_attributes.merge(
      provider_profile_attributes(patient, first_name, middle_name, identity[:iin])
    ).merge(
      'medelement_last_synced_at' => Time.current.iso8601,
      'medelement_patient_code' => identity[:patient_code].to_s,
      'phone_conflict_comment' => phone_conflict_comment,
      'secondary_phones' => secondary_phones(contact, patient, primary_phone)
    ).compact
    update_shared_phone_owner!(contact, patient)
    contact.save!
    record_phone_conflict(identity[:patient_code], contact, phone_conflict_comment) if phone_conflict_comment.present?
    enqueue_shared_phone_promotion(contact)
    contact
  end

  # M5(a): event driven, after this patient's sync commits; the job re-checks everything under the phone lock.
  def enqueue_shared_phone_promotion(contact)
    return unless Contacts::SharedPhonePromotionPolicy.auto_candidate?(contact)

    contact_id = contact.id
    ActiveRecord.after_all_transactions_commit { Contacts::SharedPhonePromotionJob.perform_later(contact_id) }
  end

  # A contact that owns a channel identity (ContactInbox) keeps its primary phone and gets a new provider phone as
  # secondary. A card without channel identity follows the provider phone only when it is free (M1): nobody holds it,
  # nobody chats from it, and it is not reserved for an unresolved hidden share. The card's own recorded доп. номер is
  # never taken here; it becomes primary only through Contacts::SharedPhonePromotionService.
  def assignable_provider_phone(contact, patient)
    current_phone = Integrations::Medelement::PhoneNumber.normalize(contact.phone_number)
    return current_phone if current_phone.present? && channel_identity_owner?(contact)

    share_phone = Contacts::SharedPhone.share_of(contact)&.phone
    available_phones = provider_phones(patient).select do |phone|
      phone != share_phone && Contacts::SharedPhone.assignable_primary?(account_id: account.id, phone: phone, contact_id: contact.id)
    end
    return current_phone if available_phones.include?(current_phone)

    provider_phones(patient).first if available_phones.include?(provider_phones(patient).first)
  end

  def channel_identity_owner?(contact)
    contact.persisted? && ContactInbox.exists?(contact_id: contact.id)
  end

  # The MedElement phone of a card without its own primary is recorded as a share with whoever holds it (primary
  # holder, the single contact chatting from it, or the owner of an unresolved hidden share). A recorded share whose
  # number nobody holds any more is kept: the number stays the card's доп. номер until it is promoted.
  def update_shared_phone_owner!(contact, patient)
    return Contacts::SharedPhone.clear_share!(contact.custom_attributes) if contact.phone_number.present?

    phone = provider_phones(patient).first
    return if phone.blank?

    current = Contacts::SharedPhone.share_of(contact)
    share = Contacts::SharedPhone.existing_share_for(account_id: account.id, phone: phone, excluding: [contact.id],
                                                     preferred_owner_id: current&.owner_id)
    return if share.blank?

    conversation_id = share[:conversation_id] || (current.conversation_id if current&.owner_id == share[:owner_id])
    Contacts::SharedPhone.record_share!(contact.custom_attributes, phone: phone, owner_id: share[:owner_id], via: share[:via],
                                                                   conversation_id: conversation_id)
  end

  def provider_profile_attributes(patient, first_name, middle_name, iin)
    {
      'address' => patient['FULL_ADDRESS'].to_s.presence,
      'birth_date' => normalize_birth_date(patient['BIRTHDAY']),
      'gender' => gender_value(patient),
      'iin' => iin,
      'medelement_address' => patient['FULL_ADDRESS'].to_s.presence,
      'medelement_birth_date' => normalize_birth_date(patient['BIRTHDAY']),
      'medelement_email' => patient['PATIENT_EMAIL'].to_s.downcase.presence,
      'medelement_first_name' => first_name,
      'medelement_gender' => gender_value(patient),
      'medelement_iin' => iin,
      'medelement_last_name' => patient['LASTNAME'].to_s.presence,
      'medelement_middle_name' => middle_name,
      # '' records "synced, MedElement has no phone" so the M9 report can complete (a missing key means not synced yet).
      Contacts::SharedPhone::MEDELEMENT_PHONE_KEY => provider_phones(patient).first.to_s
    }.compact
  end

  def foreign_owner?(contact)
    contact.owner_id.present? && !account.users.exists?(id: contact.owner_id)
  end

  def preserve_foreign_owner_contact(contact, patient_code)
    conflict_tracker&.record!(
      phase: 'contacts',
      entity_type: 'contact',
      conflict_type: 'foreign_contact_owner',
      entity_key: patient_code.presence || "contact:#{contact.id}",
      severity: 'error',
      details: { reason: 'Contact owner does not belong to the integration account', contact_id: contact.id }
    )
    contact
  end

  def record_phone_conflict(patient_code, contact, comment)
    conflict_type = comment.include?('belongs to') ? 'phone_owned_by_another_contact' : 'phone_mismatch'
    conflicting_contact_id = comment[/contact #(\d+)/, 1]&.to_i
    conflict_tracker&.record!(
      phase: 'contacts',
      entity_type: 'contact',
      conflict_type: conflict_type,
      entity_key: patient_code.presence || "contact:#{contact.id}",
      details: {
        contact_id: contact.id,
        conflicting_contact_id: conflicting_contact_id,
        reason: conflict_type,
        local_phone_last4: Integrations::Medelement::PhoneNumber.normalize(contact.phone_number).to_s.last(4),
        provider_phone_last4: provider_phone_from_comment(comment).to_s.last(4)
      }.compact
    )
  end

  def provider_phone_from_comment(comment)
    comment.to_s[/(?:Medelement phone|Phone) (\+\d+)/, 1]
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
end
# rubocop:enable Metrics/ClassLength
