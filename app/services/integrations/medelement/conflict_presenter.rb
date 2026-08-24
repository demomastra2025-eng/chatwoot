class Integrations::Medelement::ConflictPresenter
  CONTACT_CONFLICT_TYPES = %w[
    patient_not_found patient_update_rejected phone_owned_by_another_contact phone_mismatch
  ].freeze
  MEDELEMENT_WRITABLE_FIELDS = %i[first_name last_name middle_name phone iin birth_date gender email].freeze

  def initialize(conflict:, entity_preloader: nil)
    @conflict = conflict
    @entity_preloader = entity_preloader
  end

  def payload
    conflict.api_payload.merge(
      contact_resolution: contact_resolution_payload,
      entity_context: Integrations::Medelement::ConflictEntityPresenter.new(
        conflict: conflict,
        preloader: entity_preloader
      ).payload
    ).compact
  end

  private

  attr_reader :conflict, :entity_preloader

  # rubocop:disable Metrics/CyclomaticComplexity
  def contact_resolution_payload
    return unless contact_conflict?

    primary_contact = scoped_contact(conflict.details['contact_id'])
    conflicting_contact = scoped_contact(conflicting_contact_id(primary_contact))
    return if primary_contact.blank? && conflicting_contact.blank?

    {
      primary_contact: contact_payload(primary_contact),
      conflicting_contact: contact_payload(conflicting_contact),
      field_comparisons: field_comparisons(primary_contact),
      can_merge: immutable_conflicting_contact? && both_contacts?(primary_contact, conflicting_contact),
      can_sync_fields: conflict.open? && conflict.conflict_type == 'phone_mismatch' && primary_contact.present?,
      can_delete_primary: deletable?(primary_contact),
      can_delete_conflicting: immutable_conflicting_contact? && deletable?(conflicting_contact)
    }
  end

  # rubocop:enable Metrics/CyclomaticComplexity
  def conflicting_contact_id(primary_contact)
    conflict.details['conflicting_contact_id'].presence ||
      primary_contact&.custom_attributes&.dig('phone_conflict_comment').to_s[/contact #(\d+)/, 1]
  end

  def scoped_contact(contact_id)
    return if contact_id.blank?

    conflict.account.contacts.find_by(id: contact_id)
  end

  def contact_payload(contact)
    return if contact.blank?

    contact_identity_payload(contact).merge(contact_relation_payload(contact))
  end

  def contact_identity_payload(contact)
    {
      id: contact.id,
      name: contact.name,
      email: contact.email,
      phone_number: contact.phone_number,
      identifier_masked: mask_identifier(contact.identifier),
      contact_type: contact.contact_type,
      patient_code: contact.custom_attributes['medelement_patient_code'],
      secondary_phones: Array(contact.custom_attributes['secondary_phones']).compact_blank.first(10),
      last_activity_at: contact.last_activity_at&.iso8601
    }
  end

  def contact_relation_payload(contact)
    {
      conversations_count: contact.conversations.count,
      appointments_count: contact.scheduling_appointments.count,
      deals_count: contact.crm_deals.distinct.count,
      call_sessions_count: Telephony::CallSession.where(account_id: contact.account_id, contact_id: contact.id).count
    }
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def field_comparisons(contact)
    return [] if contact.blank?

    attributes = contact.custom_attributes.to_h
    provider_iin = attributes['medelement_iin'] || attributes['iin']
    values = {
      first_name: [contact.name, attributes['medelement_first_name']],
      last_name: [contact.last_name, attributes['medelement_last_name']],
      middle_name: [contact.middle_name, attributes['medelement_middle_name']],
      phone: [contact.phone_number, provider_phone(contact)],
      iin: [mask_identifier(contact.identifier), mask_identifier(provider_iin)],
      birth_date: [attributes['birth_date'], attributes['medelement_birth_date'] || attributes['birth_date']],
      gender: [attributes['gender'], attributes['medelement_gender'] || attributes['gender']],
      email: [contact.email, attributes['medelement_email'] || contact.email],
      address: [attributes['address'], attributes['medelement_address'] || attributes['address']]
    }

    values.map do |field, (onelink_value, medelement_value)|
      {
        field: field,
        onelink_value: onelink_value,
        medelement_value: medelement_value,
        differs: field_differs?(field, onelink_value, medelement_value, contact.identifier, provider_iin),
        can_sync_to_onelink: medelement_value.present?,
        can_sync_to_medelement: medelement_writes_enabled? && field.in?(MEDELEMENT_WRITABLE_FIELDS) && onelink_value.present?
      }
    end
  end

  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def provider_phone(contact)
    comment_phone = contact.custom_attributes['phone_conflict_comment'].to_s[/Medelement phone (\+\d+)/, 1]
    comment_phone.presence || Array(contact.custom_attributes['secondary_phones']).compact_blank.find do |phone|
      Integrations::Medelement::PhoneNumber.normalize(phone) != Integrations::Medelement::PhoneNumber.normalize(contact.phone_number)
    end
  end

  def medelement_writes_enabled?
    conflict.hook.enabled? && conflict.hook.feature_allowed? &&
      Integrations::Medelement::Configuration.new(hook: conflict.hook).write_enabled?
  end

  def normalized_value(value)
    value.to_s.squish.downcase
  end

  def field_differs?(field, onelink_value, medelement_value, onelink_iin, medelement_iin)
    return normalized_value(onelink_iin) != normalized_value(medelement_iin) if field == :iin

    normalized_value(onelink_value) != normalized_value(medelement_value)
  end

  def contact_conflict?
    conflict.entity_type == 'contact' || conflict.conflict_type.in?(CONTACT_CONFLICT_TYPES)
  end

  def both_contacts?(primary_contact, conflicting_contact)
    primary_contact.present? && conflicting_contact.present?
  end

  def immutable_conflicting_contact?
    conflict.details['conflicting_contact_id'].present?
  end

  def deletable?(contact)
    contact.present? && safe_to_delete?(contact)
  end

  def mask_identifier(identifier)
    value = identifier.to_s
    return if value.blank?
    return value if value.length <= 4

    "#{'*' * (value.length - 4)}#{value.last(4)}"
  end

  def safe_to_delete?(contact)
    Integrations::Medelement::ContactResolutionService.safe_to_delete?(contact)
  end
end
