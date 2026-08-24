# rubocop:disable Metrics/ClassLength
class Integrations::Medelement::ContactFieldResolutionService
  class ResolutionError < StandardError; end

  class FieldAlreadyUsedError < ResolutionError
    attr_reader :field, :contact_id

    def initialize(field:, contact_id:)
      @field = field
      @contact_id = contact_id
      super("#{field} is already used by contact ##{contact_id}")
    end
  end

  FIELDS = %w[first_name last_name middle_name phone iin birth_date gender email address].freeze
  OUTBOUND_FIELDS = (FIELDS - ['address']).freeze
  DIRECTIONS = %w[medelement_to_onelink onelink_to_medelement].freeze
  UNIQUE_CONTACT_FIELDS = { 'phone' => 'phone_number', 'iin' => 'identifier', 'email' => 'email' }.freeze

  def initialize(conflict:, user:, client: nil)
    @conflict = conflict
    @user = user
    @client = client
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def perform(field_directions:)
    directions = normalize_directions(field_directions)
    validate_request!(directions)

    conflict.with_lock do
      raise ResolutionError, 'Only open conflicts can be resolved' unless conflict.open?

      contact = conflict.account.contacts.find(conflict.details.fetch('contact_id'))
      patient_code = contact.custom_attributes['medelement_patient_code'].to_s
      raise ResolutionError, 'MedElement patient reference is missing' if patient_code.blank?

      patient = medelement_client.get_patient(patient_code: patient_code)
      provider = provider_values(patient)
      local = onelink_values(contact)
      inbound_fields = fields_for(directions, 'medelement_to_onelink')
      outbound_fields = fields_for(directions, 'onelink_to_medelement')
      ensure_selected_values!(provider, inbound_fields, 'MedElement')
      ensure_selected_values!(local, outbound_fields, 'OneLink')
      ensure_unique_inbound_fields!(contact, provider, inbound_fields)

      desired_provider = apply_onelink_fields!(contact, patient_code, outbound_fields, provider, local)
      apply_provider_fields!(contact, provider, inbound_fields, desired_provider) if inbound_fields.present?

      conflict.update!(
        status: 'resolved',
        resolved_by: user,
        resolved_at: Time.current,
        resolution_note: "Fields synchronized: #{directions.map { |field, direction| "#{field}=#{direction}" }.join(', ')}"
      )
    end
  end

  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
  private

  attr_reader :conflict, :user, :client

  def normalize_directions(field_directions)
    values = if field_directions.respond_to?(:to_unsafe_h)
               field_directions.to_unsafe_h
             elsif field_directions.respond_to?(:to_h)
               field_directions.to_h
             else
               raise ArgumentError, 'Field directions must be an object'
             end
    values.stringify_keys.transform_values(&:to_s)
  end

  def validate_request!(directions)
    raise ResolutionError, 'Field synchronization is only available for phone mismatches' unless conflict.conflict_type == 'phone_mismatch'
    raise ArgumentError, 'Select at least one supported field direction' if directions.empty? || (directions.keys - FIELDS).any?
    raise ArgumentError, 'Unsupported synchronization direction' if (directions.values - DIRECTIONS).any?

    validate_outbound_request!(directions)
  end

  def validate_outbound_request!(directions)
    outbound_fields = fields_for(directions, 'onelink_to_medelement')

    raise ArgumentError, 'Selected field cannot be written to MedElement' if outbound_fields.intersect?(FIELDS - OUTBOUND_FIELDS)

    return if outbound_fields.empty?
    return if conflict.hook.enabled? && conflict.hook.feature_allowed? && configuration.write_enabled?

    raise ResolutionError, 'MedElement writes are disabled for this integration'
  end

  def fields_for(directions, direction)
    directions.select { |_field, selected_direction| selected_direction == direction }.keys
  end

  def medelement_client
    @medelement_client ||= client || Integrations::Medelement::Client.new(configuration: configuration)
  end

  def configuration
    @configuration ||= Integrations::Medelement::Configuration.new(hook: conflict.hook)
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def apply_provider_fields!(contact, provider, fields, provider_snapshot)
    attributes = {}
    custom = contact.custom_attributes.to_h
    attributes['name'] = provider['first_name'] if fields.include?('first_name')
    attributes['last_name'] = provider['last_name'] if fields.include?('last_name')
    attributes['middle_name'] = provider['middle_name'] if fields.include?('middle_name')
    attributes['phone_number'] = provider['phone'] if fields.include?('phone')
    attributes['identifier'] = provider['iin'] if fields.include?('iin')
    attributes['email'] = provider['email'] if fields.include?('email')
    %w[birth_date gender address].each { |field| custom[field] = provider[field] if fields.include?(field) }
    apply_provider_snapshot!(custom, provider_snapshot)
    if fields.include?('phone')
      custom['secondary_phones'] = merged_secondary_phones(contact, provider['phone'])
      custom.delete('phone_conflict_comment')
    end

    contact.skip_runtime_events = true
    contact.update!(attributes.merge('custom_attributes' => custom))
  end

  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def apply_onelink_fields!(contact, patient_code, fields, provider, local)
    return provider if fields.empty?

    desired = provider.merge(local.slice(*fields))
    payload = patient_payload(contact, patient_code, desired)

    Integrations::Medelement::ProviderScope.validate_write!(payload, organization_id: configuration.organization_id)
    medelement_client.update_patient(params: payload)

    custom = contact.custom_attributes.to_h
    apply_provider_snapshot!(custom, desired)
    custom.delete('phone_conflict_comment') if fields.include?('phone')
    contact.skip_runtime_events = true
    contact.update!(custom_attributes: custom)
    desired
  end

  # rubocop:disable Metrics/MethodLength
  def patient_payload(contact, patient_code, values)
    Integrations::Medelement::ProviderCommands::PatientPayloadBuilder.new(
      contact: contact,
      patient_code: patient_code,
      phone_number: values['phone'],
      organization_id: configuration.organization_id,
      desired_attributes: {
        'name' => values['first_name'],
        'last_name' => values['last_name'],
        'middle_name' => values['middle_name'],
        'email' => values['email'],
        'gender' => values['gender'],
        'custom_attributes' => {
          'medelement_first_name' => values['first_name'],
          'medelement_last_name' => values['last_name'],
          'medelement_middle_name' => values['middle_name'],
          'medelement_iin' => values['iin'],
          'medelement_birth_date' => values['birth_date'],
          'medelement_gender' => values['gender']
        }
      }
    ).build
  end

  # rubocop:enable Metrics/MethodLength
  def provider_values(patient)
    {
      'first_name' => patient['NAME'].to_s.presence,
      'last_name' => patient['LASTNAME'].to_s.presence,
      'middle_name' => patient['MIDDLENAME'].to_s.presence,
      'phone' => Integrations::Medelement::PhoneNumber.patient_phones(patient).first,
      'iin' => normalized_iin(patient['IIN']),
      'birth_date' => normalized_date(patient['BIRTHDAY']),
      'gender' => provider_gender(patient['GENDER']),
      'email' => patient['PATIENT_EMAIL'].to_s.downcase.presence,
      'address' => patient['FULL_ADDRESS'].to_s.presence
    }
  end

  # rubocop:disable Metrics/AbcSize
  def onelink_values(contact)
    custom = contact.custom_attributes.to_h
    {
      'first_name' => contact.name.to_s.presence,
      'last_name' => contact.last_name.to_s.presence,
      'middle_name' => contact.middle_name.to_s.presence,
      'phone' => Integrations::Medelement::PhoneNumber.normalize(contact.phone_number),
      'iin' => normalized_iin(contact.identifier.presence || custom['iin']),
      'birth_date' => normalized_date(custom['birth_date']),
      'gender' => custom['gender'].to_s.presence,
      'email' => contact.email.to_s.downcase.presence,
      'address' => custom['address'].to_s.presence
    }
  end

  # rubocop:enable Metrics/AbcSize
  def apply_provider_snapshot!(custom, values)
    custom.merge!(
      'medelement_first_name' => values['first_name'],
      'medelement_last_name' => values['last_name'],
      'medelement_middle_name' => values['middle_name'],
      'medelement_iin' => values['iin'],
      'medelement_birth_date' => values['birth_date'],
      'medelement_gender' => values['gender'],
      'medelement_email' => values['email'],
      'medelement_address' => values['address']
    )
  end

  def merged_secondary_phones(contact, provider_phone)
    current = Integrations::Medelement::PhoneNumber.normalize(contact.phone_number)
    (Array(contact.custom_attributes['secondary_phones']) + [current]).compact_blank.filter_map do |phone|
      Integrations::Medelement::PhoneNumber.normalize(phone)
    end.uniq - [provider_phone]
  end

  def ensure_selected_values!(values, fields, source)
    missing = fields.select { |field| values[field].blank? }
    raise ResolutionError, "#{source} has no value for: #{missing.join(', ')}" if missing.present?
  end

  def ensure_unique_inbound_fields!(contact, provider, fields)
    UNIQUE_CONTACT_FIELDS.slice(*fields).each do |field, attribute|
      scope = contact.account.contacts.where.not(id: contact.id)
      duplicate = if attribute == 'email'
                    scope.where('LOWER(email) = ?', provider[field].downcase).first
                  else
                    scope.find_by(attribute => provider[field])
                  end
      raise FieldAlreadyUsedError.new(field: field, contact_id: duplicate.id) if duplicate
    end
  end

  def normalized_iin(value)
    value.to_s.gsub(/\D/, '').presence
  end

  def normalized_date(value)
    return if value.blank?

    Date.parse(value.to_s).iso8601
  rescue Date::Error
    nil
  end

  def provider_gender(value)
    { '1' => 'female', '2' => 'male', 'female' => 'female', 'male' => 'male' }[value.to_s.downcase]
  end
end
# rubocop:enable Metrics/ClassLength
