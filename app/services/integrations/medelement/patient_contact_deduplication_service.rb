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
    contact = linked_contact || identity_contact
    owner = phone_owner
    contact ||= owner if patient_code_for(owner) == patient_code
    contact ||= account.contacts.new
    Result.new(contact: contact, phone_conflict_comment: phone_conflict(owner, contact))
  end

  private

  attr_reader :account, :patient_code, :provider_phones, :linked_contact, :identity_contact

  def patient_code_for(contact)
    contact&.custom_attributes.to_h['medelement_patient_code'].to_s.presence
  end

  def phone_owner
    account.contacts.lock.find_by(phone_number: provider_phones.first) if provider_phones.first.present?
  end

  # A phone owner without a MedElement code is the family communication contact: the patient card shares its
  # number intentionally, so only an owner bound to another provider patient is reported for review.
  def phone_conflict(owner, contact)
    return if owner.nil? || owner.id == contact.id || patient_code_for(owner).blank?

    "Phone #{provider_phones.first} already belongs to MedElement patient contact ##{owner.id}"
  end
end
