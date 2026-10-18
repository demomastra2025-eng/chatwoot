class Integrations::Medelement::PatientContactDeduplicationService
  Result = Struct.new(:contact, :phone_conflict_comment, keyword_init: true)

  def initialize(account:, patient_code:, provider_phones:, linked_contact:, **options)
    @account = account
    @patient_code = patient_code.to_s
    @provider_phones = Array(provider_phones).compact_blank.uniq
    @linked_contact = linked_contact
    @identity_contact = options[:identity_contact]
    @iin = options[:iin].to_s.presence
  end

  def perform
    return result(linked_contact || identity_contact || account.contacts.new) if provider_phone.blank?

    phone_owner ? resolve_owned_phone : resolve_free_phone
  end

  private

  attr_reader :account, :patient_code, :provider_phones, :linked_contact, :identity_contact, :iin

  def provider_phone
    provider_phones.first
  end

  def linked_contact_phone
    @linked_contact_phone ||= Integrations::Medelement::PhoneNumber.normalize(linked_contact&.phone_number)
  end

  def phone_owner
    @phone_owner ||= account.contacts.lock.find_by(phone_number: provider_phone)
  end

  def linked_contact_owns_provider_phone?
    linked_contact.present? && (phone_owner&.id == linked_contact.id || provider_phones.include?(linked_contact_phone))
  end

  def resolve_owned_phone
    return result(linked_contact) if linked_contact_owns_provider_phone?
    return claim_local_phone_contact(phone_owner) if claimable_local_phone_owner?(phone_owner)
    return result(phone_owner) if patient_code_matches?(phone_owner, patient_code)

    conflicting_patient_contact(phone_owner)
  end

  def resolve_free_phone
    return result(linked_contact) if linked_contact && (linked_contact.phone_number.blank? || provider_phones.include?(linked_contact_phone))
    return result(identity_contact || account.contacts.new) if linked_contact.blank?

    move_linked_patient_to(account.contacts.new(phone_number: provider_phone))
  end

  def claimable_local_phone_owner?(owner)
    owner.present? && patient_code_for(owner).blank? && !unclaimable_owner_identity?(owner)
  end

  def unclaimable_owner_identity?(owner)
    Contacts::SharedPhone.card_identity_recorded?(owner) ||
      Contacts::SharedPhone.self_declared_identity?(owner, iin) ||
      !owner_iin_compatible?(owner)
  end

  def owner_iin_compatible?(owner)
    owner_iins = [
      owner.identifier,
      owner.custom_attributes.to_h['iin'],
      owner.custom_attributes.to_h['medelement_iin']
    ].filter_map { |value| Scheduling::IinValidator.normalize(value) if Scheduling::IinValidator.valid?(value) }.uniq
    owner_iins.empty? || (iin.present? && owner_iins == [iin])
  end

  def claim_local_phone_contact(owner)
    merge_linked_contact_into_owner!(owner) if linked_contact.present? && linked_contact.id != owner.id
    result(owner.reload)
  end

  def merge_linked_contact_into_owner!(owner)
    transfer_patient_contact!(linked_contact, owner)
    linked_contact.destroy! if linked_contact.reload.phone_number.blank? && Contacts::ReferenceMergeService.safe_to_delete?(linked_contact)
  end

  def conflicting_patient_contact(owner)
    destination = if linked_contact && linked_contact.phone_number.blank?
                    linked_contact
                  elsif linked_contact && linked_contact.phone_number.present?
                    account.contacts.create!.tap { |new_contact| transfer_patient_contact!(linked_contact, new_contact) }
                  else
                    reusable_identity_contact(owner) || account.contacts.new
                  end
    result(destination, phone_conflict(owner, destination))
  end

  def reusable_identity_contact(owner)
    identity_contact if identity_contact.present? && identity_contact.id != owner&.id && identity_contact.phone_number.blank?
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
    contact&.custom_attributes.to_h['medelement_patient_code'].to_s.presence
  end

  def patient_code_matches?(contact, code)
    patient_code_for(contact) == code ||
      Array(contact&.custom_attributes.to_h['medelement_merged_patient_codes']).map(&:to_s).include?(code.to_s)
  end

  def phone_conflict(owner, contact)
    return if owner.nil? || owner.id == contact.id || patient_code_for(owner).blank?

    "Phone #{provider_phone} already belongs to MedElement patient contact ##{owner.id}"
  end

  def result(contact, comment = nil)
    Result.new(contact: contact, phone_conflict_comment: comment)
  end
end
