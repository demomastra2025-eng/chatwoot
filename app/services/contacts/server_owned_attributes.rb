# Custom attributes that only the server writes: MedElement data, patient-card shares, promotion hints and the number
# transfer log (the revert task relies on it), plus доп. номера and phone conflict notes. The dashboard contacts API
# refuses changes to them (Integrations::Medelement::ProviderOwnedAttributesGuard); untrusted writers (widget visitors,
# public API clients, Captain tools, CSV imports) can never set, change or delete them, their values are dropped.
module Contacts::ServerOwnedAttributes
  PREFIX = Integrations::Medelement::ProviderOwnedAttributesGuard::PREFIX
  KEYS = %w[secondary_phones phone_conflict_comment].freeze

  module_function

  def managed_key?(key) = key.to_s.start_with?(PREFIX) || KEYS.include?(key.to_s)

  def strip(incoming)
    return incoming if incoming.blank?

    incoming.to_h.stringify_keys.reject { |key, _value| managed_key?(key) }
  end

  def strip_keys(keys) = Array(keys).reject { |key| managed_key?(key) }

  # Untrusted writers (widget/public identify, public API create, Captain tools, audience import) cannot prove a number
  # is theirs, so they never take as primary a number that is reserved for another contact's unresolved hidden share
  # (M2) or recorded as another contact's shared доп. номер (M1, for example a family number released by the mother).
  # The recorded share owner itself may take it back. contact_id nil means a contact that does not exist yet.
  def reserved_for_other?(account_id:, phone:, contact_id:)
    return false if phone.blank?

    normalized = normalized_phone(phone)
    reserved = Contacts::SharedPhone.reservation_owner_ids(account_id: account_id, phone: normalized)
    return true if reserved.any? && reserved.exclude?(contact_id)

    shared_with_other?(account_id, normalized, contact_id)
  end

  def shared_with_other?(account_id, phone, contact_id)
    Contacts::SharedPhone.recorded_shares(account_id: account_id, phone: phone).any? do |card_id, owner_id|
      contact_id.nil? || (card_id != contact_id && owner_id != contact_id)
    end
  end

  def normalized_phone(phone) = Contacts::PhoneNumberNormalizer.normalize(phone.to_s) || phone.to_s

  # A family number: some card has it as a recorded shared доп. номер. An unverified writer that sends it (widget identify
  # or pre-chat, public API create, lead forms) proves nothing about it, so it is never used to merge or attach that
  # writer into the contact holding the number (the holder's chats then receive the card's notifications, M3).
  def family_number?(account_id:, phone:)
    return false if phone.blank?

    Contacts::SharedPhone.recorded_shares(account_id: account_id, phone: normalized_phone(phone)).any?
  end

  # Unverified contact create (public API, lead forms): an identifier, email or phone that belongs to a patient card
  # never attaches the new chat to that card (the value is dropped and a separate contact is created) unless the
  # identifier was HMAC-verified and is the card's own; a family number is never used to attach to its holder, and a
  # free number another contact reserved or shares is not taken.
  def unverified_create_attributes(account:, attributes:, verified_identifier: nil)
    attributes = attributes.to_h.with_indifferent_access
    attributes[:custom_attributes] = strip(attributes[:custom_attributes]) if attributes[:custom_attributes]
    %i[identifier email phone_number].each do |key|
      attributes.delete(key) if patient_card_value?(account, key, attributes[key], verified_identifier)
    end
    attributes.delete(:phone_number) if unclaimable_phone?(account, attributes[:phone_number]) ||
                                        family_number?(account_id: account.id, phone: attributes[:phone_number])
    attributes
  end

  def patient_card_value?(account, key, value, verified_identifier)
    existing = existing_contact(account, key, value)
    return false unless existing && Contacts::SharedPhone.card?(existing)

    !(key == :identifier && verified_identifier.present? && existing.identifier == verified_identifier.to_s)
  end

  def existing_contact(account, key, value)
    return if value.blank?
    return account.contacts.find_by(identifier: value) if key == :identifier
    return account.contacts.from_email(value) if key == :email

    account.contacts.find_by(phone_number: Contacts::PhoneNumberNormalizer.normalize(value.to_s) || value)
  end

  def unclaimable_phone?(account, phone)
    return false if phone.blank?

    normalized = normalized_phone(phone)
    Contacts::SharedPhone.primary_holder(account_id: account.id, phone: normalized).blank? &&
      reserved_for_other?(account_id: account.id, phone: normalized, contact_id: nil)
  end
end
