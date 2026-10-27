class Scheduling::PatientContextQuery
  CONTACT_IDS_KEY = 'medelement_patient_context_contact_ids'.freeze

  def initialize(account:, contact:)
    @account = account
    @contact = contact
    raise ArgumentError, 'Contact must belong to the account' unless contact.account_id == account.id
  end

  def patients
    ids = [contact.id] + appointment_patient_ids + shared_patient_ids + recorded_patient_ids
    account.contacts.where(id: ids.uniq).order(:id).to_a.sort_by { |card| card.id == contact.id ? 0 : 1 }
  end

  private

  attr_reader :account, :contact

  def appointment_patient_ids
    account.scheduling_appointments.where(contact_id: contact.id).where.not(patient_contact_id: nil).distinct.pluck(:patient_contact_id)
  end

  def recorded_patient_ids
    account.contacts.where('custom_attributes -> ? @> ?::jsonb', CONTACT_IDS_KEY, [contact.id].to_json).pluck(:id)
  end

  def shared_patient_ids
    share = Contacts::SharedPhone.share_of(contact)
    phone = contact.phone_number.presence || share&.phone
    cards = account.contacts.where('custom_attributes ->> ? = ?', Contacts::SharedPhone::SHARED_OWNER_KEY, contact.id.to_s).to_a
    if phone.present?
      ids = Contacts::SharedPhone.recorded_shares(account_id: account.id, phone: phone).flatten.compact
      cards += account.contacts.where(id: ids).to_a
    end
    cards.select do |card|
      card.id == contact.id || Contacts::SharedPhone.share_of(card).present? || (phone.present? && card.phone_number == phone)
    end.map(&:id)
  end
end
