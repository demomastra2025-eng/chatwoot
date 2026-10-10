module Captain::Playground::SchedulingTools
  private

  def resource!(id)
    record = record!('resources', id)
    raise ArgumentError, 'Specialist is unavailable' unless record['active']

    record
  end

  def service!(id, resource: nil)
    record = record!('services', id)
    raise ArgumentError, 'Service is unavailable' unless record['active']
    raise ArgumentError, 'Service is not available for this specialist' if resource && !resource['service_ids'].include?(record['id'])

    record
  end

  def scheduling_resources
    records = @data['resources'].select { |record| record['active'] }
    query = @args['query'].presence || @args['name'].presence || @args['specialty'].presence
    records = records.select { |record| [record['name'], record['specialty']].join(' ').downcase.include?(query.downcase) } if query
    records = records.select { |record| record['service_ids'].include?(@args['service_id'].to_i) } if @args['service_id']
    { resources: records.deep_dup, total_count: records.size, simulated: true }
  end

  def scheduling_services
    records = @data['services'].select { |record| record['active'] }
    query = @args['query'].presence || @args['name'].presence
    records = records.select { |record| record['name'].downcase.include?(query.downcase) } if query
    if @args['resource_id']
      resource = resource!(@args['resource_id'])
      records = records.select { |record| resource['service_ids'].include?(record['id']) }
    end
    { services: records.deep_dup, total_count: records.size, simulated: true }
  end

  def parse_time(value)
    raise ArgumentError, 'Datetime must include an explicit timezone' unless value.to_s.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)

    Time.iso8601(value.to_s)
  rescue ArgumentError
    raise ArgumentError, 'Invalid ISO 8601 datetime with timezone'
  end

  def duration_for(resource, service_id, duration_min)
    service = service!(service_id, resource: resource) if service_id.present?
    duration = Integer(duration_min || service&.fetch('duration_min', nil) || 30)
    raise ArgumentError, 'Duration must be between 5 and 240 minutes' unless duration.between?(5, 240)

    duration
  end

  def slot_available?(resource, starts_at, ends_at, exclude_id: nil)
    local_start = starts_at.in_time_zone(@data['timezone'])
    local_end = ends_at.in_time_zone(@data['timezone'])
    return false unless local_start.to_date == local_end.to_date && local_start.hour >= 9 && local_end.hour <= 18 &&
                        (local_end.hour < 18 || local_end.min.zero?)

    @data['appointments'].none? do |record|
      record['id'] != exclude_id && record['resource_id'] == resource['id'] && record['status'] != 'cancelled' &&
        parse_time(record['starts_at']) < ends_at && parse_time(record['ends_at']) > starts_at
    end
  end

  def available_slots
    from = parse_time(@args.fetch('from'))
    to = parse_time(@args.fetch('to'))
    raise ArgumentError, 'Availability range must be positive and at most 14 days' unless to > from && to - from <= 14.days

    resources = @args['resource_ids'].present? ? @args['resource_ids'].map { |id| resource!(id) } : @data['resources'].select { |record| record['active'] }
    resources = resources.select { |record| record['service_ids'].include?(@args['service_id'].to_i) } if @args['service_id']
    raise ArgumentError, 'Service is not available for these specialists' if resources.empty? && @args['service_id']

    limit = Integer(@args['limit'] || 20).clamp(1, 100)
    slots = []
    resources.each do |resource|
      duration = duration_for(resource, @args['service_id'], @args['duration_min'])
      zone = ActiveSupport::TimeZone[@data['timezone']] || Time.zone
      date = from.in_time_zone(zone).to_date
      while date <= to.in_time_zone(zone).to_date && slots.size < limit
        cursor = zone.local(date.year, date.month, date.day, 9)
        while cursor.hour < 18 && slots.size < limit
          ending = cursor + duration.minutes
          if cursor >= from && cursor >= Time.current && ending <= to && slot_available?(resource, cursor, ending)
            slots << { resource_id: resource['id'], resource_name: resource['name'], starts_at: cursor.iso8601, ends_at: ending.iso8601,
                       duration_min: duration, service_id: @args['service_id'], source: 'local', simulated: true }.compact
          end
          cursor += 30.minutes
        end
        date += 1.day
      end
    end
    { slots: slots.sort_by { |slot| slot[:starts_at] }, total_slots: slots.size, requested_service_id: @args['service_id'],
      service_match: { confirmed: @args['service_id'].present?, resource_ids: resources.map { |resource| resource['id'] } }, simulated: true }
  end

  def create_appointment
    resource = resource!(@args.fetch('resource_id'))
    start = parse_time(@args.fetch('starts_at'))
    duration = duration_for(resource, @args['service_id'], @args['duration_min'])
    ending = @args['ends_at'] ? parse_time(@args['ends_at']) : start + duration.minutes
    raise ArgumentError, 'Appointment must start in the future and end after its start' unless start >= Time.current && ending > start
    return { success: false, reason: 'time_taken' } unless slot_available?(resource, start, ending)

    patient = resolve_patient
    appointment = {
      'id' => @scenario.next_id!, 'resource_id' => resource['id'], 'service_id' => @args['service_id'],
      'contact_id' => caller['id'], 'patient_contact_id' => patient['id'], 'conversation_id' => @data['conversation']['id'],
      'client_name' => patient['name'], 'client_phone' => patient_phone(patient), 'client_identifier' => patient['identifier'],
      'client_birth_date' => patient['custom_attributes'].to_h['birth_date'], 'starts_at' => start.iso8601, 'ends_at' => ending.iso8601,
      'duration_min' => ((ending - start) / 60).to_i, 'status' => 'scheduled', 'appointment_type' => appointment_type,
      'client_comment' => @args['client_comment'], 'custom_attributes' => json_object(@args['custom_attributes'])
    }.compact
    @data['appointments'] << appointment
    appointment_result(appointment, action: 'create_appointment')
  end

  def appointment_type
    value = @args['appointment_type'].presence || 'primary'
    raise ArgumentError, 'Invalid appointment type' unless %w[primary secondary other].include?(value)

    value
  end

  def search_appointments
    require_caller_filter!
    records = @data['appointments']
    family_lookup = @args['client_identifier'].present? || bounded_name_lookup?
    if @args['client_identifier'].present?
      iin = normalized_iin(@args['client_identifier'])
      records = records.select { |record| record['client_identifier'] == iin }
    elsif family_lookup
      records = records.select { |record| record['client_name'].to_s.casecmp?(@args['client_name'].to_s.strip) }
    else
      records = records.select { |record| record['patient_contact_id'] == caller['id'] }
      records = records.select { |record| record['client_name'].to_s.downcase.include?(@args['client_name'].downcase) } if @args['client_name'].present?
    end
    records = records.select { |record| record['resource_id'] == @args['resource_id'].to_i } if @args['resource_id']
    records = records.select { |record| record['status'] == @args['status'] } if @args['status']
    from = parse_time(@args['from']) if @args['from']
    to = parse_time(@args['to']) if @args['to']
    raise ArgumentError, 'Invalid appointment date range' if from && to && from >= to
    records = records.select { |record| parse_time(record['starts_at']) >= from } if from
    records = records.select { |record| parse_time(record['starts_at']) < to } if to
    limited = records.sort_by { |record| record['starts_at'] }.reverse.first(20)
    { success: true, appointments: limited.map { |record| appointment_result(record, family_lookup: family_lookup).except(:success, :simulated) },
      has_more: records.size > 20, simulated: true }
  end

  def bounded_name_lookup?
    return false if @args['client_name'].blank? || @args['resource_id'].blank? || @args['from'].blank? || @args['to'].blank?

    from = parse_time(@args['from'])
    to = parse_time(@args['to'])
    to > from && to - from <= 1.day
  end

  def accessible_appointment!(write: false)
    id = @args['appointment_id'].presence || @context.state.dig(:appointment, :id)
    record = record!('appointments', id)
    return record if record['patient_contact_id'] == caller['id']

    grant = @data['grants'].find { |item| item['token'] == @args['appointment_access_token'] && item['appointment_id'] == record['id'] &&
                                        item['snapshot'] == appointment_snapshot(record) && item['expires_at'] > Time.current.to_i }
    raise ArgumentError, 'Record is not available' unless grant
    raise ArgumentError, 'Confirm the exact patient, appointment, and requested change first' if write && @args['patient_confirmed'] != true

    record
  end

  def get_appointment
    appointment_result(accessible_appointment!)
  end

  def update_appointment
    record = accessible_appointment!(write: true)
    raise ArgumentError, 'Cancelled appointments cannot be changed' if record['status'] == 'cancelled'
    resource = resource!(@args['resource_id'] || record['resource_id'])
    service_id = @args['service_id'] || record['service_id']
    duration = duration_for(resource, service_id, @args['duration_min'] || record['duration_min'])
    start = @args['starts_at'] ? parse_time(@args['starts_at']) : parse_time(record['starts_at'])
    ending = @args['ends_at'] ? parse_time(@args['ends_at']) : start + duration.minutes
    raise ArgumentError, 'Appointment must start in the future and end after its start' unless start >= Time.current && ending > start
    return { success: false, reason: 'time_taken' } unless slot_available?(resource, start, ending, exclude_id: record['id'])

    record.merge!('resource_id' => resource['id'], 'service_id' => service_id, 'starts_at' => start.iso8601, 'ends_at' => ending.iso8601,
                  'duration_min' => ((ending - start) / 60).to_i)
    record['appointment_type'] = appointment_type if @args['appointment_type']
    record['client_comment'] = @args['client_comment'] if @args.key?('client_comment')
    record['custom_attributes'] = record['custom_attributes'].to_h.merge(json_object(@args['custom_attributes'])) if @args['custom_attributes']
    appointment_result(record, action: 'update_appointment')
  end

  def cancel_appointment
    record = accessible_appointment!(write: true)
    raise ArgumentError, 'Appointment is already cancelled' if record['status'] == 'cancelled'

    record['status'] = 'cancelled'
    appointment_result(record, action: 'cancel_appointment')
  end

  def appointment_snapshot(record)
    Digest::SHA256.hexdigest(JSON.generate(record.sort.to_h))
  end

  def appointment_result(record, action: nil, family_lookup: false)
    card = @scenario.appointment_card(record)
    result = { success: true, appointment_id: record['id'], doctor_name: card[:doctor], local_date: card[:date], local_time: card[:time],
               status: { 'create_appointment' => 'created', 'update_appointment' => 'updated', 'cancel_appointment' => 'cancelled' }.fetch(action, card[:status]),
               simulated: true }
    if family_lookup || record['patient_contact_id'] != caller['id']
      token = "trial_#{@session.id}_#{SecureRandom.hex(20)}"
      @data['grants'] = @data['grants'].select { |grant| grant['expires_at'] > Time.current.to_i }.last(20)
      @data['grants'] << { 'token' => token, 'appointment_id' => record['id'], 'snapshot' => appointment_snapshot(record), 'expires_at' => 20.minutes.from_now.to_i }
      result.merge!(patient_name: record['client_name'], appointment_access_token: token)
    end
    result
  end

  def list_my_appointments
    records = @data['appointments'].select { |record| record['patient_contact_id'] == caller['id'] }
    status = @args['status'].presence || 'any'
    raise ArgumentError, 'Invalid status' unless %w[scheduled completed cancelled no_show any].include?(status)
    records = records.select { |record| record['status'] == status || (status == 'scheduled' && record['status'] == 'confirmed') } unless status == 'any'
    %w[date_from date_to].each { |key| Date.iso8601(@args[key]) if @args[key].present? }
    records = records.select { |record| parse_time(record['starts_at']).in_time_zone(@data['timezone']).to_date >= Date.iso8601(@args['date_from']) } if @args['date_from']
    records = records.select { |record| parse_time(record['starts_at']).in_time_zone(@data['timezone']).to_date <= Date.iso8601(@args['date_to']) } if @args['date_to']
    offset = Integer(@args['offset'] || 0)
    limit = Integer(@args['limit'] || 10).clamp(1, 20)
    raise ArgumentError, 'Invalid pagination' if offset.negative?

    { success: true, total: records.size, has_more: records.size > offset + limit,
      appointments: records.sort_by { |record| record['starts_at'] }.reverse.drop(offset).first(limit).map { |record| @scenario.appointment_card(record) }, simulated: true }
  end
end
