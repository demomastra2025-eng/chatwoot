class Captain::Playground::Scenario
  CONTACT_FIELDS = %w[name email phone_number identifier custom_attributes additional_attributes].freeze
  APPOINTMENT_FIELDS = %w[resource_id service_id starts_at ends_at duration_min status appointment_type client_comment].freeze
  DEAL_FIELDS = %w[title description amount currency pipeline_id stage_id expected_close_on win_probability custom_attributes].freeze
  MAX_RECORDS = 30
  EDITABLE_RECORDS = { 'patient' => ['contacts', CONTACT_FIELDS, 102], 'deal' => ['deals', DEAL_FIELDS, 501],
                       'appointment' => ['appointments', APPOINTMENT_FIELDS, 601] }.freeze

  extend Captain::Playground::ScenarioDefaults
  include Captain::Playground::ScenarioContext
  include Captain::Playground::ScenarioValidation

  attr_reader :data

  def initialize(data = nil, timezone: 'Asia/Almaty')
    @data = (data || self.class.default(timezone: timezone)).deep_stringify_keys
    validate!
  end

  def apply(input, mode:)
    attributes = scenario_attributes(input, mode: mode)
    contact.merge!(attributes['contact'].slice(*CONTACT_FIELDS)) if attributes.key?('contact')
    apply_trial_records(attributes) if mode == 'trial'
    validate!
    self
  end

  def contact
    data.fetch('contacts').find { |record| record['id'] == data['caller_contact_id'] } || raise(ArgumentError, 'Caller is required')
  end

  def next_id!
    id = data['next_id']
    data['next_id'] += 1
    id
  end

  def validate
    validate!
    self
  end

  private

  def scenario_attributes(input, mode:)
    raise ArgumentError, 'Scenario must be an object' unless input.is_a?(Hash)

    attributes = input.deep_stringify_keys
    raise ArgumentError, 'Live only accepts the test caller profile' if mode == 'live' && (attributes.keys - ['contact']).any?

    %w[contact patient deal appointment].each do |key|
      raise ArgumentError, 'Scenario records must be objects' if attributes.key?(key) && !attributes[key].is_a?(Hash)
    end
    attributes
  end

  def apply_trial_records(attributes)
    EDITABLE_RECORDS.each do |key, (collection, fields, id)|
      apply_record(collection, attributes[key], fields, id: id) if attributes.key?(key)
    end
    refresh_patient_snapshots!
  end

  def apply_record(collection, value, fields, id:)
    record = data.fetch(collection).find { |item| item['id'] == id }
    raise ArgumentError, 'Scenario record is unavailable; reset the trial to restore it' unless record

    record.merge!(value.slice(*fields))
    return unless collection == 'appointments' && value.key?('starts_at') && !value.key?('ends_at')

    record['ends_at'] = (Time.iso8601(record['starts_at']) + record['duration_min'].to_i.minutes).iso8601
  end

  def refresh_patient_snapshots!
    data['contacts'].each { |record| refresh_contact_identity!(record) }
    data['deals'].each { |record| refresh_deal_stage!(record) }
    data['appointments'].each { |record| refresh_appointment_patient!(record) }
  end

  def refresh_contact_identity!(record)
    attributes = record['custom_attributes']
    raise ArgumentError, 'Contact custom attributes must be an object' unless attributes.is_a?(Hash)

    attributes['iin'] = record['identifier'] if record['identifier'].present?
    return unless record['id'] == 102

    first, last, *middle = record['name'].to_s.squish.split(' ')
    attributes.merge!('medelement_first_name' => first, 'medelement_last_name' => last, 'medelement_middle_name' => middle.join(' ').presence)
  end

  def refresh_deal_stage!(record)
    stage = data['stages'].find { |item| item['id'] == record['stage_id'] && item['pipeline_id'] == record['pipeline_id'] }
    raise ArgumentError, 'Stage is not available for this pipeline' unless stage

    record['stage_name'] = stage['name']
  end

  def refresh_appointment_patient!(record)
    patient = data['contacts'].find { |item| item['id'] == record['patient_contact_id'] }
    return unless patient

    phone = patient['phone_number'].presence || Array(patient.dig('custom_attributes', 'secondary_phones')).first
    record.merge!('client_name' => patient['name'], 'client_phone' => phone, 'client_identifier' => patient['identifier'],
                  'client_birth_date' => patient.dig('custom_attributes', 'birth_date'))
  end
end
