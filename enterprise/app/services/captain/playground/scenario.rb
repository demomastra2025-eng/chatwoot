class Captain::Playground::Scenario
  CONTACT_FIELDS = %w[name email phone_number identifier custom_attributes additional_attributes].freeze
  APPOINTMENT_FIELDS = %w[resource_id service_id starts_at ends_at duration_min status appointment_type client_comment].freeze
  DEAL_FIELDS = %w[title description amount currency pipeline_id stage_id expected_close_on win_probability custom_attributes].freeze
  MAX_RECORDS = 30

  attr_reader :data

  def initialize(data = nil, timezone: 'Asia/Almaty')
    @data = (data || self.class.default(timezone: timezone)).deep_stringify_keys
    validate!
  end

  def self.default(timezone: 'Asia/Almaty')
    zone = ActiveSupport::TimeZone[timezone.presence || 'Asia/Almaty'] || Time.zone
    day = 2.days.from_now.in_time_zone(zone).to_date
    starts = zone.local(day.year, day.month, day.day, 11)
    mother = { id: 101, name: 'Айгуль Садыкова', phone_number: '+77010000001', identifier: '900101400013',
               email: 'aigul@example.test', contact_type: 'customer', custom_attributes: { birth_date: '1990-01-01', iin: '900101400013' },
               additional_attributes: {} }
    son = { id: 102, name: 'Тимур Садыков', phone_number: '+77010000002', identifier: '150101500011',
            contact_type: 'customer', custom_attributes: { birth_date: '2015-01-01', iin: '150101500011' }, additional_attributes: {} }
    {
      preset: 'mother_and_son', timezone: zone.name, caller_contact_id: 101,
      contacts: [mother, son],
      conversation: { id: 201, display_id: 1, inbox_id: 401, contact_id: 101, status: 'open', priority: nil,
                      label_list: [], custom_attributes: {}, additional_attributes: {} },
      resources: [{ id: 701, name: 'Елена Иванова', timezone: zone.name, active: true, specialty: 'Педиатр', service_ids: [801] },
                  { id: 702, name: 'Алексей Петров', timezone: zone.name, active: true, specialty: 'Терапевт', service_ids: [802] }],
      services: [{ id: 801, name: 'Приём педиатра', duration_min: 30, amount: 10000, active: true },
                 { id: 802, name: 'Приём терапевта', duration_min: 30, amount: 12000, active: true }],
      pipelines: [{ id: 901, name: 'Записи', code: 'bookings', default: true }],
      stages: [{ id: 911, pipeline_id: 901, name: 'Новая заявка', code: 'new', stage_type: 'open' },
               { id: 912, pipeline_id: 901, name: 'Записан', code: 'booked', stage_type: 'open' },
               { id: 913, pipeline_id: 901, name: 'Завершён', code: 'won', stage_type: 'won' }],
      deals: [{ id: 501, contact_id: 101, title: 'Запись семьи Садыковых', description: '', amount: 10000, currency: 'KZT',
                pipeline_id: 901, pipeline_name: 'Записи', stage_id: 911, stage_name: 'Новая заявка', originating_conversation_id: 201,
                custom_attributes: {} }],
      appointments: [{ id: 601, resource_id: 701, service_id: 801, contact_id: 102, patient_contact_id: 102, conversation_id: nil,
                       client_name: son[:name], client_phone: son[:phone_number], client_identifier: son[:identifier],
                       client_birth_date: '2015-01-01', starts_at: starts.iso8601, ends_at: (starts + 30.minutes).iso8601,
                       duration_min: 30, status: 'scheduled', appointment_type: 'primary', custom_attributes: {} }],
      tasks: [], notes: [], messages: [], confirmations: [], grants: [],
      next_id: 1001
    }.deep_stringify_keys
  end

  def self.live_default(timezone: 'Asia/Almaty')
    profile = default(timezone: timezone)
    profile['contacts'] = [profile['contacts'].first.except('id', 'identifier')]
    profile['caller_contact_id'] = nil
    profile['conversation'] = {}
    profile['preset'] = 'test_caller'
    profile['next_id'] = nil
    %w[resources services pipelines stages deals appointments tasks notes messages confirmations grants].each do |key|
      profile[key] = []
    end
    profile
  end

  def apply(input, mode:)
    raise ArgumentError, 'Scenario must be an object' unless input.is_a?(Hash)
    attributes = input.deep_stringify_keys
    raise ArgumentError, 'Live only accepts the test caller profile' if mode == 'live' && (attributes.keys - ['contact']).any?
    %w[contact patient deal appointment].each do |key|
      raise ArgumentError, 'Scenario records must be objects' if attributes.key?(key) && !attributes[key].is_a?(Hash)
    end

    contact.merge!(attributes['contact'].to_h.slice(*CONTACT_FIELDS)) if attributes.key?('contact')
    if mode == 'trial'
      apply_record('contacts', attributes['patient'], CONTACT_FIELDS, id: 102) if attributes.key?('patient')
      apply_record('deals', attributes['deal'], DEAL_FIELDS, id: 501) if attributes.key?('deal')
      apply_record('appointments', attributes['appointment'], APPOINTMENT_FIELDS, id: 601) if attributes.key?('appointment')
      refresh_patient_snapshots!
    end
    validate!
    self
  end

  def contact
    data.fetch('contacts').find { |record| record['id'] == data['caller_contact_id'] } || raise(ArgumentError, 'Caller is required')
  end

  def state
    caller_appointments = data['appointments'].select { |record| record['patient_contact_id'] == contact['id'] }
    appointment = caller_appointments.reject { |record| record['status'] == 'cancelled' }.min_by { |record| record['starts_at'].to_s }
    {
      contact: contact.deep_symbolize_keys,
      conversation: data['conversation'].deep_symbolize_keys,
      contact_inbox: { id: 301, hmac_verified: false }, channel_type: 'Channel::Api',
      communication_thread: { id: 201, current_conversation_id: 201, conversation_ids: [201], contact_id: contact['id'], channels: [] },
      deal: data['deals'].find { |record| record['contact_id'] == contact['id'] }&.deep_symbolize_keys,
      task: data['tasks'].find { |record| record['contact_id'] == contact['id'] }&.deep_symbolize_keys,
      appointment: appointment_state(appointment),
      appointment_context_blocks: appointment_blocks(caller_appointments)
    }.compact
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

  def public_data(mode:)
    result = { contact: contact.deep_dup }
    return result if mode == 'live'

    result.merge(patient: data['contacts'].find { |record| record['id'] == 102 }, deal: data['deals'].find { |record| record['id'] == 501 },
                 appointment: data['appointments'].find { |record| record['id'] == 601 }, resources: data['resources'], services: data['services'],
                 stages: data['stages'], contacts: data['contacts'], deals: data['deals'], appointments: data['appointments'])
  end

  def appointment_card(record)
    return unless record

    start = Time.iso8601(record['starts_at']).in_time_zone(data['timezone'])
    resource = data['resources'].find { |item| item['id'] == record['resource_id'] }
    service = data['services'].find { |item| item['id'] == record['service_id'] }
    { id: record['id'], status: record['status'] == 'confirmed' ? 'scheduled' : record['status'], date: start.strftime('%d.%m.%Y'),
      time: start.strftime('%H:%M'), doctor: resource&.fetch('name', nil), service: service&.fetch('name', nil) }
  end

  private

  def apply_record(collection, value, fields, id:)
    raise ArgumentError, 'Scenario record must be an object' unless value.is_a?(Hash)

    record = data.fetch(collection).find { |item| item['id'] == id }
    raise ArgumentError, 'Scenario record is unavailable; reset the trial to restore it' unless record

    record.merge!(value.slice(*fields))
    if collection == 'appointments' && value.key?('starts_at') && !value.key?('ends_at')
      record['ends_at'] = (Time.iso8601(record['starts_at']) + record['duration_min'].to_i.minutes).iso8601
    end
  end

  def refresh_patient_snapshots!
    data['contacts'].each { |record| record['custom_attributes']['iin'] = record['identifier'] if record['identifier'].present? }
    data['deals'].each do |record|
      stage = data['stages'].find { |item| item['id'] == record['stage_id'] && item['pipeline_id'] == record['pipeline_id'] }
      raise ArgumentError, 'Stage is not available for this pipeline' unless stage

      record['stage_name'] = stage['name']
    end
    data['appointments'].each do |record|
      patient = data['contacts'].find { |item| item['id'] == record['patient_contact_id'] }
      next unless patient

      record.merge!('client_name' => patient['name'], 'client_phone' => patient['phone_number'], 'client_identifier' => patient['identifier'])
    end
  end

  def validate!
    %w[contacts resources services pipelines stages deals appointments tasks notes messages confirmations grants].each do |key|
      records = data[key]
      raise ArgumentError, "Invalid scenario #{key}" unless records.is_a?(Array) && records.size <= MAX_RECORDS && records.all? { |item| item.is_a?(Hash) }
    end
    data['contacts'].each do |item|
      raise ArgumentError, 'Contact name is required' if item['name'].blank? || item['name'].to_s.length > 255
      phone = item['phone_number']
      raise ArgumentError, 'Contact phone must use E.164 format' if phone.present? && !phone.to_s.match?(/\A\+[1-9]\d{7,14}\z/)
      raise ArgumentError, 'Contact custom attributes must be an object' unless item['custom_attributes'].is_a?(Hash)
    end
    data['deals'].each do |item|
      amount = BigDecimal(item['amount'].to_s)
      raise ArgumentError, 'Deal amount must be a nonnegative whole number' unless amount.finite? && amount >= 0 && amount.frac.zero?
    end
    data['appointments'].each do |item|
      raise ArgumentError, 'Appointment end must be after its start' unless Time.iso8601(item['ends_at']) > Time.iso8601(item['starts_at'])
      raise ArgumentError, 'Unknown appointment resource' unless data['resources'].any? { |resource| resource['id'] == item['resource_id'] }
      raise ArgumentError, 'Unknown appointment service' if item['service_id'].present? && data['services'].none? { |service| service['id'] == item['service_id'] }
      resource = data['resources'].find { |record| record['id'] == item['resource_id'] }
      raise ArgumentError, 'Service is not available for this specialist' if item['service_id'].present? && !resource['service_ids'].include?(item['service_id'])
    end
  end

  def appointment_state(record)
    return unless record

    card = appointment_card(record)
    record.deep_symbolize_keys.merge(resource_name: card[:doctor], start_date: card[:date], start_time: card[:time])
  end

  def appointment_blocks(records)
    now = Time.current
    active = records.reject { |item| item['status'] == 'cancelled' }
    upcoming, past = active.partition { |item| Time.iso8601(item['ends_at']) > now }
    cancelled = records.select { |item| item['status'] == 'cancelled' }
    {
      nearest: appointment_card(upcoming.min_by { |item| item['starts_at'] }),
      last_past: appointment_card(past.max_by { |item| item['starts_at'] }),
      last_cancelled: appointment_card(cancelled.max_by { |item| item['starts_at'] }),
      all: { total: records.size, upcoming: upcoming.size, past: past.size, cancelled: cancelled.size,
             appointments: records.first(6).map { |item| appointment_card(item) }, empty: records.empty? ? 'нет записей' : nil }
    }.transform_values { |value| JSON.generate(value) }
  end
end
