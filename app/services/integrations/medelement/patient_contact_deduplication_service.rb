class Integrations::Medelement::PatientContactDeduplicationService
  Result = Data.define(:contact, :phone_conflict_comment)

  def initialize(account:, patient_code:, provider_phones:, linked_contact:, identity_contact:)
    @account = account
    @patient_code = patient_code.to_s
    @provider_phones = provider_phones
    @linked_contact = linked_contact
    @identity_contact = identity_contact
  end

  def perform
    return result(linked_contact || identity_contact || account.contacts.new) if provider_phone.blank?

    phone_owner ? resolve_owned_phone : resolve_free_phone
  end

  private

  attr_reader :account, :patient_code, :provider_phones, :linked_contact, :identity_contact

  def provider_phone
    provider_phones.first
  end

  def phone_owner
    @phone_owner ||= account.contacts.lock.find_by(phone_number: provider_phone)
  end

  def linked_contact_owns_provider_phone?
    linked_contact.present? && phone_owner&.id == linked_contact.id
  end

  def local_phone_owner?
    phone_owner.present? && patient_code_for(phone_owner).blank?
  end

  def resolve_owned_phone
    return result(linked_contact) if linked_contact_owns_provider_phone?
    return claim_local_phone_contact if local_phone_owner?

    conflicting_patient_contact
  end

  def resolve_free_phone
    return result(linked_contact) if linked_contact && linked_contact.phone_number.blank?
    return result(identity_contact) if linked_contact.blank? && identity_contact

    move_linked_patient_to(account.contacts.new(phone_number: provider_phone))
  end

  def claim_local_phone_contact
    transfer_patient_contact!(linked_contact, phone_owner) if linked_contact && linked_contact.id != phone_owner.id
    result(phone_owner)
  end

  def conflicting_patient_contact
    destination = if linked_contact && linked_contact.phone_number.blank?
                    linked_contact
                  else
                    account.contacts.create!.tap do |new_contact|
                      transfer_patient_contact!(linked_contact, new_contact) if linked_contact
                    end
                  end
    comment = "Phone #{provider_phone} already belongs to MedElement patient contact ##{phone_owner.id}"
    result(destination, comment)
  end

  def move_linked_patient_to(destination)
    transfer_patient_contact!(linked_contact, destination) if linked_contact
    result(destination)
  end

  def transfer_patient_contact!(source_contact, destination_contact)
    destination_contact.save! if destination_contact.new_record?
    Integrations::Medelement::PatientContactTransferService.new(
      account: account,
      source_contact: source_contact,
      destination_contact: destination_contact
    ).perform
  end

  def patient_code_for(contact)
    contact.custom_attributes.to_h['medelement_patient_code'].to_s.presence
  end

  def result(contact, comment = nil)
    Result.new(contact: contact, phone_conflict_comment: comment)
  end
end
