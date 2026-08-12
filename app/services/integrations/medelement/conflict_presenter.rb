class Integrations::Medelement::ConflictPresenter
  CONTACT_CONFLICT_TYPES = %w[
    patient_not_found patient_update_rejected phone_owned_by_another_contact phone_mismatch
  ].freeze

  def initialize(conflict:)
    @conflict = conflict
  end

  def payload
    conflict.api_payload.merge(
      contact_resolution: contact_resolution_payload
    ).compact
  end

  private

  attr_reader :conflict

  def contact_resolution_payload
    return unless contact_conflict?

    primary_contact = scoped_contact(conflict.details['contact_id'])
    conflicting_contact = scoped_contact(conflicting_contact_id(primary_contact))
    return if primary_contact.blank? && conflicting_contact.blank?

    {
      primary_contact: contact_payload(primary_contact),
      conflicting_contact: contact_payload(conflicting_contact),
      can_merge: immutable_conflicting_contact? && both_contacts?(primary_contact, conflicting_contact),
      can_delete_primary: deletable?(primary_contact),
      can_delete_conflicting: immutable_conflicting_contact? && deletable?(conflicting_contact)
    }
  end

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
