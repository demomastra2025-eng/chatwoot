class Integrations::Medelement::ProviderCommands::PatientPayloadBuilder
  # rubocop:disable Metrics/ParameterLists
  def initialize(contact:, patient_code: nil, phone_number: nil, identity: nil, organization_id: nil, desired_attributes: {})
    @contact = contact
    @patient_code = patient_code
    @desired_attributes = desired_attributes.to_h.deep_stringify_keys
    @phone_number = phone_number.presence || contact_attribute('phone_number')
    @identity = identity.to_h.stringify_keys
    @organization_id = organization_id
  end
  # rubocop:enable Metrics/ParameterLists

  def build
    values = name_values

    {
      'profile_code' => patient_code.presence,
      'company_code' => organization_id.to_s.presence,
      'name' => values.fetch(:first_name),
      'lastname' => values.fetch(:last_name),
      'middlename' => values[:middle_name],
      'patient_email' => contact_attribute('email').to_s.presence,
      'birthday' => birthday,
      'gender' => gender_code,
      'iin' => iin
    }.merge(phone_payload).compact
  end

  private

  attr_reader :contact, :patient_code, :phone_number, :identity, :organization_id, :desired_attributes

  def custom_attributes
    @custom_attributes ||= desired_attributes.fetch('custom_attributes', contact.custom_attributes).to_h
  end

  def phone_payload
    components = Integrations::Medelement::PhoneNumber.new(phone_number).components
    {
      'patient_phone_2[0]' => components.fetch(0),
      'patient_phone_2[1]' => components.fetch(1),
      'patient_phone_2[2]' => components.fetch(2)
    }
  end

  def name_values
    return appointment_name_values if appointment_identity?

    explicit = explicit_name_values
    return explicit if explicit[:first_name].present? && explicit[:last_name].present?

    contact_name_values
  end

  def explicit_name_values
    last_name = custom_attributes['medelement_last_name'].presence || contact_attribute('last_name').to_s.presence
    {
      first_name: custom_attributes['medelement_first_name'].presence || (contact_attribute('name').to_s.presence if last_name.present?),
      last_name: last_name,
      middle_name: custom_attributes['medelement_middle_name'].presence || contact_attribute('middle_name').to_s.presence
    }
  end

  def contact_name_values
    parts = contact_attribute('name').to_s.split
    validate_name_parts!(parts)

    { last_name: parts.first, first_name: parts.second, middle_name: parts.drop(2).join(' ').presence }
  end

  def appointment_name_values
    explicit = {
      first_name: identity['first_name'].to_s.presence,
      last_name: identity['last_name'].to_s.presence,
      middle_name: identity['middle_name'].to_s.presence
    }
    if explicit[:first_name].present?
      validate_name_values!(explicit)
      return explicit
    end

    parts = identity.fetch('full_name').to_s.split
    validate_name_parts!(parts)

    { last_name: parts.first, first_name: parts.second, middle_name: parts.drop(2).join(' ').presence }
  end

  def validate_name_parts!(parts)
    return if parts.size >= 2

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_PATIENT_NAME_INCOMPLETE',
      message: 'Patient first and last name are required for Medelement',
      status: :unprocessable_content
    )
  end

  def validate_name_values!(values)
    return if values[:first_name].present? && values[:last_name].present?

    raise Scheduling::Error.new(
      code: 'MEDELEMENT_PATIENT_NAME_INCOMPLETE',
      message: 'Patient first and last name are required for Medelement',
      status: :unprocessable_content
    )
  end

  def appointment_identity?
    identity['first_name'].present? || identity['full_name'].present?
  end

  def iin
    candidates = if appointment_identity?
                   [identity['iin']]
                 else
                   [custom_attributes['medelement_iin'], custom_attributes['iin'], contact_attribute('identifier')]
                 end
    value = candidates.find { |candidate| Scheduling::IinValidator.valid?(candidate) }
    Scheduling::IinValidator.normalize(value) if value
  end

  def birthday
    value = if appointment_identity?
              identity['birth_date'].presence
            else
              custom_attributes['medelement_birth_date'].presence || custom_attributes['birth_date'].presence
            end
    value ||= iin_birth_date
    return if value.blank?

    Date.parse(value.to_s).strftime('%d.%m.%Y')
  rescue Date::Error
    nil
  end

  def gender_code
    contact_gender = contact_attribute('gender') if contact.respond_to?(:gender)
    value = if appointment_identity?
              identity['gender'].presence
            else
              contact_gender.presence || custom_attributes['medelement_gender'].presence || custom_attributes['gender'].presence
            end
    { 'female' => 1, 'male' => 2, '1' => 1, '2' => 2 }[value.to_s] || iin_gender_code
  end

  def iin_birth_date
    value = iin
    return if value.blank?

    century = { '1' => 1800, '2' => 1800, '3' => 1900, '4' => 1900, '5' => 2000, '6' => 2000 }[value[6]]
    return if century.blank?

    Date.new(century + value[0, 2].to_i, value[2, 2].to_i, value[4, 2].to_i)
  rescue Date::Error
    nil
  end

  def iin_gender_code
    value = iin
    return if value.blank?

    value[6].to_i.odd? ? 2 : 1
  end

  def contact_attribute(key)
    desired_attributes.fetch(key.to_s) { contact.public_send(key) }
  end
end
