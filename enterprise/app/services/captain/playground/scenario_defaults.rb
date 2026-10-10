module Captain::Playground::ScenarioDefaults
  def default(timezone: 'Asia/Almaty')
    zone = ActiveSupport::TimeZone[timezone.presence || 'Asia/Almaty'] || Time.zone
    day = 2.days.from_now.in_time_zone(zone).to_date
    starts = zone.local(day.year, day.month, day.day, 11)
    mother = default_caller
    son = default_patient
    {
      preset: 'mother_and_son', timezone: zone.name, caller_contact_id: 101, contacts: [mother, son],
      conversation: { id: 201, display_id: 1, inbox_id: 401, contact_id: 101, status: 'open', priority: nil,
                      label_list: [], custom_attributes: {}, additional_attributes: {} },
      appointments: [default_appointment(starts, son)], tasks: [], notes: [], messages: [], confirmations: [], grants: [], next_id: 1001
    }.merge(default_clinic(zone)).merge(default_deals).deep_stringify_keys
  end

  def live_default(timezone: 'Asia/Almaty')
    profile = default(timezone: timezone)
    profile.merge!('contacts' => [profile['contacts'].first.except('id', 'identifier')], 'caller_contact_id' => nil,
                   'conversation' => {}, 'preset' => 'test_caller', 'next_id' => nil)
    %w[resources services pipelines stages deals appointments tasks notes messages confirmations grants].each { |key| profile[key] = [] }
    profile
  end

  private

  def default_caller
    { id: 101, name: 'Айгуль Садыкова', phone_number: '+77010000001', identifier: '900101400013',
      email: 'aigul@example.test', contact_type: 'customer', custom_attributes: { birth_date: '1990-01-01', iin: '900101400013' },
      additional_attributes: {} }
  end

  def default_patient
    { id: 102, name: 'Тимур Садыков', phone_number: '+77010000002', identifier: '150101500011',
      contact_type: 'customer', custom_attributes: { birth_date: '2015-01-01', iin: '150101500011', medelement_patient_card: true,
                                                     medelement_first_name: 'Тимур', medelement_last_name: 'Садыков' }, additional_attributes: {} }
  end

  def default_clinic(zone)
    {
      resources: [{ id: 701, name: 'Елена Иванова', timezone: zone.name, active: true, specialty: 'Педиатр', service_ids: [801] },
                  { id: 702, name: 'Алексей Петров', timezone: zone.name, active: true, specialty: 'Терапевт', service_ids: [802] }],
      services: [{ id: 801, name: 'Приём педиатра', duration_min: 30, amount: 10_000, active: true },
                 { id: 802, name: 'Приём терапевта', duration_min: 30, amount: 12_000, active: true }]
    }
  end

  def default_deals
    {
      pipelines: [{ id: 901, name: 'Записи', code: 'bookings', default: true }],
      stages: [{ id: 911, pipeline_id: 901, name: 'Новая заявка', code: 'new', stage_type: 'open' },
               { id: 912, pipeline_id: 901, name: 'Записан', code: 'booked', stage_type: 'open' },
               { id: 913, pipeline_id: 901, name: 'Завершён', code: 'won', stage_type: 'won' }],
      deals: [{ id: 501, contact_id: 101, title: 'Запись семьи Садыковых', description: '', amount: 10_000, currency: 'KZT',
                pipeline_id: 901, pipeline_name: 'Записи', stage_id: 911, stage_name: 'Новая заявка', originating_conversation_id: 201,
                custom_attributes: {} }]
    }
  end

  def default_appointment(starts, son)
    { id: 601, resource_id: 701, service_id: 801, contact_id: 102, patient_contact_id: 102, conversation_id: nil,
      client_name: son[:name], client_phone: son[:phone_number], client_identifier: son[:identifier], client_birth_date: '2015-01-01',
      starts_at: starts.iso8601, ends_at: (starts + 30.minutes).iso8601, duration_min: 30,
      status: 'scheduled', appointment_type: 'primary', custom_attributes: {} }
  end
end
