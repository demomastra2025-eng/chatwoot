module Captain::Playground::SchedulingTools
  private

  def create_appointment
    slot = appointment_slot
    return { success: false, reason: 'time_taken' } unless slot_available?(slot[:resource], slot[:start], slot[:ending])

    patient = resolve_patient
    appointment = appointment_identity_attributes(patient).merge(slot_attributes(slot)).merge(
      'status' => 'scheduled', 'appointment_type' => appointment_type,
      'client_comment' => @args['client_comment'], 'custom_attributes' => json_object(@args['custom_attributes'])
    ).compact
    @data['appointments'] << appointment
    appointment_result(appointment, action: 'create_appointment')
  end

  def appointment_identity_attributes(patient)
    {
      'id' => @scenario.next_id!,
      'contact_id' => caller['id'], 'patient_contact_id' => patient['id'], 'conversation_id' => @data['conversation']['id'],
      'client_name' => patient['name'], 'client_phone' => patient_phone(patient), 'client_identifier' => patient['identifier'],
      'client_birth_date' => patient['custom_attributes'].to_h['birth_date']
    }
  end

  def appointment_slot(record = nil)
    fields = %w[resource_id service_id duration_min starts_at]
    inputs = record.to_h.slice(*fields).merge(@args.slice(*fields))
    resource = resource!(inputs.fetch('resource_id'))
    service_id = inputs['service_id']
    duration = duration_for(resource, service_id, inputs['duration_min'])
    start = parse_time(inputs.fetch('starts_at'))
    ending = @args['ends_at'] ? parse_time(@args['ends_at']) : start + duration.minutes
    raise ArgumentError, 'Appointment must start in the future and end after its start' unless start >= Time.current && ending > start

    { resource: resource, service_id: service_id, start: start, ending: ending }
  end

  def slot_attributes(slot)
    { 'resource_id' => slot[:resource]['id'], 'service_id' => slot[:service_id],
      'starts_at' => slot[:start].iso8601, 'ends_at' => slot[:ending].iso8601,
      'duration_min' => ((slot[:ending] - slot[:start]) / 60).to_i }
  end

  def appointment_type
    value = @args['appointment_type'].presence || 'primary'
    raise ArgumentError, 'Invalid appointment type' unless %w[primary secondary other].include?(value)

    value
  end

  def update_appointment
    record = accessible_appointment!(write: true)
    raise ArgumentError, 'Cancelled appointments cannot be changed' if record['status'] == 'cancelled'

    slot = appointment_slot(record)
    return { success: false, reason: 'time_taken' } unless slot_available?(slot[:resource], slot[:start], slot[:ending], exclude_id: record['id'])

    record.merge!(slot_attributes(slot))
    apply_appointment_extras!(record)
    appointment_result(record, action: 'update_appointment')
  end

  def apply_appointment_extras!(record)
    record['appointment_type'] = appointment_type if @args['appointment_type']
    record['client_comment'] = @args['client_comment'] if @args.key?('client_comment')
    record['custom_attributes'] = record['custom_attributes'].to_h.merge(json_object(@args['custom_attributes'])) if @args['custom_attributes']
  end

  def cancel_appointment
    record = accessible_appointment!(write: true)
    raise ArgumentError, 'Appointment is already cancelled' if record['status'] == 'cancelled'

    record['status'] = 'cancelled'
    appointment_result(record, action: 'cancel_appointment')
  end
end
