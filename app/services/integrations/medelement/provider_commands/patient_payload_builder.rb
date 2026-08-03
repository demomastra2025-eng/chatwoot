class Integrations::Medelement::ProviderCommands::PatientPayloadBuilder
  def initialize(contact:, patient_code: nil, phone_number: nil)
    @contact = contact
    @patient_code = patient_code
    @phone_number = phone_number || contact.phone_number
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
      'iin' => custom_attributes['medelement_iin'].presence || custom_attributes['iin'].presence
    }.merge(phone_payload).compact
  end

  private

  attr_reader :contact, :patient_code, :phone_number

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
    explicit = {
      first_name: custom_attributes['medelement_first_name'].presence,
      last_name: custom_attributes['medelement_last_name'].presence,
      middle_name: custom_attributes['medelement_middle_name'].presence
    }
    return explicit if explicit[:first_name].present? && explicit[:last_name].present?

    parts = contact.name.to_s.split
    if parts.size < 2
      raise Scheduling::Error.new(
        code: 'MEDELEMENT_PATIENT_NAME_INCOMPLETE',
        message: 'Patient first and last name are required for Medelement',
        status: :unprocessable_content
      )
    end

    { last_name: parts.first, first_name: parts.second, middle_name: parts.drop(2).join(' ').presence }
  end

  def birthday
    value = custom_attributes['medelement_birth_date'].presence || custom_attributes['birth_date'].presence
    return if value.blank?

    Date.parse(value.to_s).strftime('%d.%m.%Y')
  rescue Date::Error
    nil
  end

  def gender_code
    contact_gender = contact.gender if contact.respond_to?(:gender)
    value = contact_gender.presence || custom_attributes['medelement_gender'].presence || custom_attributes['gender'].presence
    { 'female' => 1, 'male' => 2, '1' => 1, '2' => 2 }[value.to_s]
  end
end
