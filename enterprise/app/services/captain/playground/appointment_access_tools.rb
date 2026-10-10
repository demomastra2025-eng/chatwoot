module Captain::Playground::AppointmentAccessTools
  private

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

  def appointment_details
    appointment_result(accessible_appointment!)
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
end
