class Captain::Tools::Copilot::UpdateMyContactService < Captain::Tools::Copilot::BaseAccountTool
  FIELDS = %i[first_name last_name middle_name iin birth_date gender phone_number email].freeze

  # The failure names the birth date, so the agent can ask the patient for a correct one instead of retrying blindly.
  class InvalidBirthDate < ArgumentError; end

  def self.name
    'update_my_contact'
  end

  description 'Update the current conversation contact profile'
  param :first_name, type: :string, desc: 'First name', required: false
  param :last_name, type: :string, desc: 'Last name', required: false
  param :middle_name, type: :string, desc: 'Middle name', required: false
  param :iin, type: :string, desc: 'Kazakhstan individual identification number', required: false
  param :birth_date, type: :string, desc: 'Birth date in YYYY-MM-DD', required: false
  param :gender, type: :string, desc: 'male or female', required: false
  param :phone_number, type: :string, desc: 'Phone number in E.164 format', required: false
  param :email, type: :string, desc: 'Email address', required: false

  def execute(**fields)
    contact = scoped_contact
    return formatted_payload(success: false, reason: 'not_found') if contact.blank?
    raise ArgumentError, 'Unknown field' unless (fields.keys - FIELDS).empty?

    contact.update!(contact_updates(contact, fields))
    formatted_payload(success: true, contact: Captain::Tools::Copilot::GetMyContactService.payload(contact.reload))
  rescue InvalidBirthDate
    formatted_payload(success: false, reason: 'validation_error', field: 'birth_date')
  rescue ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    formatted_payload(success: false, reason: 'validation_error')
  end

  def active?
    user_has_permission('contact_manage')
  end

  private

  def scoped_contact
    patient_scope ? patient_scope.contacts.first : current_contact
  end

  def contact_updates(contact, fields)
    attributes = fields.slice(:first_name, :last_name, :middle_name, :iin, :phone_number, :email)
                       .transform_values { |value| value.is_a?(String) ? value.strip.presence : value }
    attributes[:name] = attributes.delete(:first_name) if attributes.key?(:first_name)
    attributes[:identifier] = validated_iin(attributes.delete(:iin)) if attributes.key?(:iin)
    validate_phone!(contact, attributes[:phone_number]) if attributes.key?(:phone_number)

    custom = custom_updates(fields, attributes)
    attributes[:custom_attributes] = CustomAttributes::MutationService.merge(contact.custom_attributes, custom) if custom.present?
    attributes
  end

  def custom_updates(fields, attributes)
    custom = {}
    custom['birth_date'] = validated_birth_date(fields[:birth_date]) if fields.key?(:birth_date)
    custom['gender'] = validated_gender(fields[:gender]) if fields.key?(:gender)
    custom['iin'] = attributes[:identifier] if attributes.key?(:identifier)
    custom
  end

  def validated_iin(value)
    return nil if value.blank?

    normalized = Scheduling::IinValidator.normalize(value)
    raise ArgumentError, 'Invalid IIN' unless Scheduling::IinValidator.valid?(normalized)

    normalized
  end

  def validated_birth_date(value)
    return nil if value.blank?

    raise InvalidBirthDate, 'Invalid birth date' unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.iso8601(value.to_s).iso8601
  rescue Date::Error
    raise InvalidBirthDate, 'Invalid birth date'
  end

  def validated_gender(value)
    return nil if value.blank?

    normalized = value.to_s.downcase
    raise ArgumentError, 'Invalid gender' unless normalized.in?(%w[male female])

    normalized
  end

  def validate_phone!(contact, phone)
    return if phone.blank?
    return unless Contacts::ServerOwnedAttributes.reserved_for_other?(
      account_id: account.id, phone: phone, contact_id: contact.id
    )

    raise ArgumentError, 'Phone is reserved'
  end
end
