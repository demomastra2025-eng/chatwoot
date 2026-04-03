class Contacts::SyncAttributes
  attr_reader :contact

  def initialize(contact)
    @contact = contact
  end

  def perform
    update_contact_location_and_country_code
    set_contact_type
  end

  private

  def update_contact_location_and_country_code
    # Ensure that location and country_code are updated from additional_attributes.
    # TODO: Remove this once all contacts are updated and both the location and country_code fields are standardized throughout the app.
    @contact.location = @contact.additional_attributes['city']
    @contact.country_code = resolved_country_code
  end

  def set_contact_type
    #  If the contact is already a lead or customer then do not change the contact type
    return unless @contact.contact_type == 'visitor'
    # If the contact has an email or phone number or social details( facebook_user_id, instagram_user_id, etc) then it is a lead
    # If contact is from external channel like facebook, instagram, whatsapp, etc then it is a lead
    return unless @contact.email.present? || @contact.phone_number.present? || social_details_present?

    @contact.contact_type = 'lead'
  end

  def social_details_present?
    @contact.additional_attributes.keys.any? do |key|
      key.start_with?('social_') && @contact.additional_attributes[key].present?
    end
  end

  def resolved_country_code
    if @contact.additional_attributes['country_code'].present?
      return normalize_country_code(@contact.additional_attributes['country_code'])
    end

    legacy_country_value = @contact.additional_attributes['country']
    return normalize_country_code(legacy_country_value) if legacy_country_value.to_s.match?(/\A[a-z]{2}\z/i)

    @contact.country_code
  end

  def normalize_country_code(value)
    return value.to_s.upcase if value.to_s.match?(/\A[a-z]{2}\z/i)

    value
  end
end
