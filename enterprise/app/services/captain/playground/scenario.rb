class Captain::Playground::Scenario
  CONTACT_FIELDS = %w[name email phone_number identifier company_id custom_attributes additional_attributes].freeze
  APPOINTMENT_FIELDS = %w[resource_id service_id starts_at ends_at duration_min status appointment_type client_comment patient_contact_id contact_id custom_attributes].freeze
  DEAL_FIELDS = %w[title description amount currency pipeline_id stage_id expected_close_on win_probability custom_attributes].freeze
  RESOURCE_FIELDS = %w[name timezone active specialty slot_duration_min service_ids work_rules break_rules holidays workday_overrides time_offs].freeze
  SERVICE_FIELDS = %w[name duration_min amount active].freeze
  PIPELINE_FIELDS = %w[name code active default restrict_stage_skipping restrict_backward_move allow_stage_rule_override].freeze
  STAGE_FIELDS = %w[name code active default position outcome stage_type closing_reason_options closing_reason_required
                    transition_reason_options transition_reason_required field_requirements].freeze
  MAX_RECORDS = 30
  FIXTURE_COLLECTIONS = %w[companies staff teams labels channel_templates touch_plans touch_plan_enrollments tasks task_statuses task_types task_outcomes
                           messages touches timelines notifications knowledge_documents knowledge_chunks faq_responses articles categories canned_responses].freeze
  EDITABLE_RECORDS = { 'patient' => ['contacts', CONTACT_FIELDS, 102], 'deal' => ['deals', DEAL_FIELDS, 501],
                       'appointment' => ['appointments', APPOINTMENT_FIELDS, 601] }.freeze

  extend Captain::Playground::ScenarioDefaults
  include Captain::Playground::ScenarioContext
  include Captain::Playground::ScenarioValidation

  attr_reader :data

  def initialize(data = nil, timezone: 'Asia/Almaty')
    @data = (data || self.class.default(timezone: timezone)).deep_stringify_keys
    (FIXTURE_COLLECTIONS + %w[touches timelines]).each { |key| @data[key] ||= [] }
    @data['task_statuses'] = Captain::Playground::TaskTools::TASK_STATUSES.deep_dup if @data['task_statuses'].empty?
    @data['selection'] ||= {}
    @data['inbox'] ||= {}
    validate!
  end

  def apply(input, mode:)
    attributes = scenario_attributes(input, mode: mode)
    contact.merge!(attributes['contact'].slice(*CONTACT_FIELDS)) if attributes.key?('contact')
    apply_trial_records(attributes)
    apply_collections(attributes)
    apply_configuration(attributes)
    apply_fixtures(attributes)
    apply_workspace_configuration(attributes)
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
    raise ArgumentError, 'Legacy Live Playground is unavailable' if mode == 'live'

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

  def apply_collections(attributes)
    { 'patients' => ['contacts', CONTACT_FIELDS, default_patient_record],
      'deals' => ['deals', DEAL_FIELDS + %w[contact_id], data['deals'].first],
      'appointments' => ['appointments', APPOINTMENT_FIELDS, data['appointments'].first] }.each do |key, (collection, fields, template)|
      next unless attributes.key?(key)

      values = attributes[key]
      raise ArgumentError, 'Scenario collections must contain records' unless values.is_a?(Array) && values.size <= MAX_RECORDS && values.all?(Hash)

      values.each do |value|
        record = value['id'] && data[collection].find { |item| item['id'] == value['id'] }
        raise ArgumentError, 'Synthetic record is not available in this session' if value['id'] && !record

        unless record
          record = template.to_h.deep_dup.merge('id' => next_id!)
          record['contact_id'] = contact['id'] if collection == 'deals'
          data[collection] << record
        end
        record.merge!(value.slice(*fields))
        if collection == 'appointments' && value.key?('starts_at') && !value.key?('ends_at')
          record['ends_at'] = (Time.iso8601(record['starts_at']) + record['duration_min'].to_i.minutes).iso8601
        end
      end
    end
    refresh_patient_snapshots!
  end

  def default_patient_record
    self.class.send(:default_patient).deep_stringify_keys
  end

  def apply_configuration(attributes)
    { 'resources' => RESOURCE_FIELDS, 'services' => SERVICE_FIELDS, 'pipelines' => PIPELINE_FIELDS, 'stages' => STAGE_FIELDS }.each do |key, fields|
      next unless attributes.key?(key)

      raise ArgumentError, 'Invalid synthetic catalogue' unless attributes[key].is_a?(Array) && attributes[key].size <= MAX_RECORDS

      attributes[key].each do |value|
        record = data[key].find { |item| item['id'] == value['id'] }
        raise ArgumentError, 'Synthetic catalogue record is not available in this session' unless record

        record.merge!(value.slice(*fields))
      end
    end
  end

  def apply_fixtures(attributes)
    FIXTURE_COLLECTIONS.each do |key|
      next unless attributes.key?(key)

      records = attributes[key]
      unless records.is_a?(Array) && records.size <= MAX_RECORDS && records.all?(Hash)
        raise ArgumentError, "Invalid synthetic #{key}"
      end
      previous = data.fetch(key)
      data[key] = records.map do |record|
        if record['id']
          raise ArgumentError, 'Synthetic record is not available in this session' unless previous.any? { |item| item['id'] == record['id'] }
        end
        record.deep_dup.merge('id' => record['id'] || next_id!)
      end
    end
  end

  def apply_record(collection, value, fields, id:)
    record = data.fetch(collection).find { |item| item['id'] == id }
    raise ArgumentError, 'Scenario record is unavailable; reset the trial to restore it' unless record

    record.merge!(value.slice(*fields))
    return unless collection == 'appointments' && value.key?('starts_at') && !value.key?('ends_at')

    record['ends_at'] = (Time.iso8601(record['starts_at']) + record['duration_min'].to_i.minutes).iso8601
  end

  def apply_workspace_configuration(attributes)
    if attributes.key?('selection')
      raise ArgumentError, 'Selection must be an object' unless attributes['selection'].is_a?(Hash)

      attributes['selection'].slice('deal_id', 'task_id', 'appointment_id').each do |key, id|
        collection = { 'deal_id' => 'deals', 'task_id' => 'tasks', 'appointment_id' => 'appointments' }.fetch(key)
        raise ArgumentError, 'Synthetic selection is not available in this session' if id.present? && data[collection].none? { |record| record['id'] == id }
      end
      data['selection'] = attributes['selection'].slice('deal_id', 'task_id', 'appointment_id')
    end
    if attributes.key?('inbox')
      raise ArgumentError, 'Synthetic inbox must be an object' unless attributes['inbox'].is_a?(Hash)

      data['inbox'] = attributes['inbox'].slice('name', 'channel_type', 'channel')
    end
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
    return if record['id'] == data['caller_contact_id']

    first, last, *middle = record['name'].to_s.squish.split(' ')
    attributes['medelement_first_name'] ||= first
    attributes['medelement_last_name'] ||= last
    attributes['medelement_middle_name'] ||= middle.join(' ').presence
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
