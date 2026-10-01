# A draft card replaced on rebind (staff added or corrected the IIN) is kept with its authored identity, but it never
# keeps the booking number: its share and the booking number are released, so it can neither hold the family number nor
# become another card's share owner. A number the draft itself chats from stays (it is a real chat identity).
class Integrations::Medelement::PatientPlaceholderRelease
  def initialize(placeholder:, phone:)
    @placeholder = placeholder
    @phone = phone
  end

  def perform
    attributes = @placeholder.custom_attributes.to_h
    shared = attributes[Contacts::SharedPhone::SHARED_PHONE_KEY]
    Contacts::SharedPhone.clear_share!(attributes)
    attributes['secondary_phones'] = Array(attributes['secondary_phones']) - [@phone, shared].compact
    @placeholder.custom_attributes = attributes
    @placeholder.phone_number = nil if releases_primary?
    @placeholder.skip_runtime_events = true
    @placeholder.save! if @placeholder.changed?
    @placeholder
  end

  private

  def releases_primary?
    @phone.present? && @placeholder.phone_number == @phone &&
      !Contacts::SharedPhone.identifying_contact_inboxes(account_id: @placeholder.account_id, phone: @phone, owner_ids: [@placeholder.id]).exists?
  end
end
