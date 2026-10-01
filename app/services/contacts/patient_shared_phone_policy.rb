# A contact that acquires its own primary number no longer routes through a shared family number: the recorded share,
# the shared number itself and any promotion hint are dropped (the card's own number has priority, M3).
class Contacts::PatientSharedPhonePolicy
  def self.apply!(contact)
    return if contact.phone_number.blank?

    attributes = contact.custom_attributes.to_h
    shared_phone = Contacts::SharedPhone
    share_recorded = attributes.key?(shared_phone::SHARED_OWNER_KEY) || attributes.key?(shared_phone::SHARED_PHONE_KEY)
    return unless share_recorded || attributes.key?(shared_phone::HINT_KEY)

    contact.custom_attributes = released_attributes(contact, attributes, share_recorded)
  end

  def self.released_attributes(contact, attributes, share_recorded)
    shared_phone = Contacts::SharedPhone
    released = attributes.except(shared_phone::HINT_KEY)
    return released unless share_recorded

    owner = contact.account.contacts.find_by(id: attributes[shared_phone::SHARED_OWNER_KEY]) if attributes[shared_phone::SHARED_OWNER_KEY]
    shared = attributes[shared_phone::SHARED_PHONE_KEY].presence || owner&.phone_number
    shared_phone.clear_share!(released).merge(
      'secondary_phones' => Array(attributes['secondary_phones']) - [shared, contact.phone_number]
    )
  end
  private_class_method :released_attributes
end
