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
    owner = phone_owner
    return claim_local_phone_contact(owner) if claimable_local_phone_owner?(owner)

    contact = linked_contact || identity_contact
    contact ||= owner if patient_code_for(owner) == patient_code
    contact ||= account.contacts.new
    Result.new(contact: contact, phone_conflict_comment: phone_conflict(owner, contact))
  end

  private

  attr_reader :account, :patient_code, :provider_phones, :linked_contact, :identity_contact, :iin

  def patient_code_for(contact)
    contact&.custom_attributes.to_h['medelement_patient_code'].to_s.presence
  end

  def phone_owner
    @phone_owner ||= account.contacts.lock.find_by(phone_number: provider_phones.first) if provider_phones.first.present?
  end

  def claimable_local_phone_owner?(owner)
    return false if owner.blank? || iin.blank? || patient_code_for(owner).present?
    return false if unclaimable_owner_identity?(owner)

    replaceable_linked_contact?(owner)
  end

  def unclaimable_owner_identity?(owner)
    Contacts::SharedPhone.card_identity_recorded?(owner) ||
      Contacts::SharedPhone.self_declared_identity?(owner, iin) ||
      !owner_iin_compatible?(owner)
  end

  def replaceable_linked_contact?(owner)
    linked_contact.blank? || linked_contact.id == owner.id || linked_contact.phone_number.blank?
  end

  def owner_iin_compatible?(owner)
    owner_iins = [
      owner.identifier,
      owner.custom_attributes.to_h['iin'],
      owner.custom_attributes.to_h['medelement_iin']
    ].filter_map { |value| Scheduling::IinValidator.normalize(value) if Scheduling::IinValidator.valid?(value) }.uniq
    owner_iins.empty? || owner_iins == [iin]
  end

  def claim_local_phone_contact(owner)
    merge_linked_contact_into_owner!(owner) if linked_contact.present? && linked_contact.id != owner.id
    Result.new(contact: owner.reload, phone_conflict_comment: nil)
  end

  def merge_linked_contact_into_owner!(owner)
    Integrations::Medelement::PatientContactTransferService.new(
      account: account,
      source_contact: linked_contact,
      destination_contact: owner
    ).perform
    linked_contact.destroy! if linked_contact.reload.phone_number.blank? && Contacts::ReferenceMergeService.safe_to_delete?(linked_contact)
  end

  def phone_conflict(owner, contact)
    return if owner.nil? || owner.id == contact.id || patient_code_for(owner).blank?

    "Phone #{provider_phones.first} already belongs to MedElement patient contact ##{owner.id}"
  end
end
