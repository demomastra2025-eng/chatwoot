class Integrations::Medelement::ProviderCommands::PatientPayloadBuilder
  def initialize(contact:, patient_code: nil, phone_number: nil, identity: nil)
    @contact = contact
    @patient_code = patient_code
    @phone_number = phone_number.presence || contact.phone_number
    @identity = identity.to_h.stringify_keys
  end

  def build
    values = name_values

    {
      'profile_code' => patient_code.presence,
      'name' => values.fetch(:first_name),
      'lastname' => values.fetch(:last_name),
      'middlename' => values[:middle_name],
      'patient_email' => contact.email.presence,
      'birthday' => birthday,
      'gender' => gender_code,
      'iin' => iin
    }.merge(phone_payload).compact
  end

  private

  attr_reader :contact, :patient_code, :phone_number, :identity

  def custom_attributes
    @custom_attributes ||= contact.custom_attributes.to_h
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
    {
      first_name: custom_attributes['medelement_first_name'].presence,
      last_name: custom_attributes['medelement_last_name'].presence,
      middle_name: custom_attributes['medelement_middle_name'].presence
    }
  end

  def contact_name_values
    parts = contact.name.to_s.split
    validate_name_parts!(parts)

    { last_name: parts.first, first_name: parts.second, middle_name: parts.drop(2).join(' ').presence }
  end

  def appointment_name_values
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

  def appointment_identity?
    identity['full_name'].present?
  end

  def iin
    return identity['iin'].presence if appointment_identity?

    custom_attributes['medelement_iin'].presence || custom_attributes['iin'].presence
  end

  def birthday
    value = if appointment_identity?
              identity['birth_date'].presence
            else
              custom_attributes['medelement_birth_date'].presence || custom_attributes['birth_date'].presence
            end
    return if value.blank?

    Date.parse(value.to_s).strftime('%d.%m.%Y')
  rescue Date::Error
    nil
  end

  def gender_code
    contact_gender = contact.gender if contact.respond_to?(:gender)
    value = if appointment_identity?
              identity['gender'].presence
            else
              contact_gender.presence || custom_attributes['medelement_gender'].presence || custom_attributes['gender'].presence
            end
    { 'female' => 1, 'male' => 2, '1' => 1, '2' => 2 }[value.to_s]
  end
end
