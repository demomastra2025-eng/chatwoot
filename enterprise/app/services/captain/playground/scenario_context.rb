module Captain::Playground::ScenarioContext
  def state
    appointments = data['appointments'].select do |record|
      record['contact_id'] == contact['id'] && (record['patient_contact_id'] || record['contact_id']) == contact['id']
    end
    {
      contact: contact.deep_symbolize_keys, conversation: data['conversation'].deep_symbolize_keys,
      contact_inbox: { id: 301, hmac_verified: false }, channel_type: 'Channel::Api',
      communication_thread: { id: 201, current_conversation_id: 201, conversation_ids: [201], contact_id: contact['id'], channels: [] }
    }.merge(business_state(appointments)).compact
  end

  def public_data(mode:)
    result = { contact: contact.deep_dup }
    return result if mode == 'live'

    result.merge(patient: data['contacts'].find { |record| record['id'] == 102 }, deal: data['deals'].find { |record| record['id'] == 501 },
                 appointment: data['appointments'].find { |record| record['id'] == 601 }).merge(trial_collections)
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

  def trial_collections
    data.slice('resources', 'services', 'stages', 'contacts', 'deals', 'appointments').symbolize_keys
  end

  def business_state(appointments)
    nearest = appointments.select { |record| record['status'] != 'cancelled' && Time.iso8601(record['ends_at']) > Time.current }
                          .min_by { |record| [Time.iso8601(record['starts_at']) <= Time.current ? 0 : 1, record['starts_at'].to_s, record['id']] }
    {
      deal: { summary: deals_summary },
      task: data['tasks'].find { |record| record['contact_id'] == contact['id'] }&.deep_symbolize_keys,
      appointment: (appointment_state(nearest) || {}).merge(summary: compact_appointments_summary(appointments)),
      appointment_context_blocks: appointment_blocks(appointments)
    }
  end

  def appointment_state(record)
    return unless record

    card = appointment_card(record)
    record.deep_symbolize_keys.merge(resource_name: card[:doctor], start_date: card[:date], start_time: card[:time])
  end

  def deals_summary
    records = data['deals'].map do |record|
      stage = data['stages'].find { |item| item['id'] == record['stage_id'] }
      record.merge('stage_outcome' => stage&.fetch('outcome', 'open'))
    end
    Captain::ContextSummary.from_snapshots(kind: 'deals', records: records, contact_id: contact['id']) do |record|
      Captain::ContextSummary.deal_card(record)
    end
  end

  def compact_appointments_summary(records)
    Captain::ContextSummary.from_snapshots(kind: 'appointments', records: records, contact_id: contact['id']) do |record|
      card = appointment_card(record)
      card.merge(title: [card[:service], card[:doctor]].compact.join(' — '), starts_at: record[:starts_at], ends_at: record[:ends_at])
    end
  end

  def appointment_blocks(records)
    active = records.reject { |item| item['status'] == 'cancelled' }
    upcoming, past = active.partition { |item| Time.iso8601(item['ends_at']) > Time.current }
    cancelled = records.select { |item| item['status'] == 'cancelled' }
    {
      nearest: appointment_card(upcoming.min_by { |item| item['starts_at'] }),
      last_past: appointment_card(past.max_by { |item| item['starts_at'] }),
      last_cancelled: appointment_card(cancelled.max_by { |item| item['starts_at'] }),
      all: appointments_summary(records, upcoming: upcoming, past: past, cancelled: cancelled)
    }.transform_values { |value| JSON.generate(value) }
  end

  def appointments_summary(records, upcoming:, past:, cancelled:)
    { total: records.size, upcoming: upcoming.size, past: past.size, cancelled: cancelled.size,
      appointments: records.first(6).map { |item| appointment_card(item) }, empty: records.empty? ? 'нет записей' : nil }
  end
end
