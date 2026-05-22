class Captain::Tools::Copilot::UpdateAppointmentService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'update_appointment'
  end

  description 'Update the appointment linked to the current conversation with a new specialist, service, or confirmed time details'
  param :resource_id, type: :number, desc: 'Updated specialist resource ID', required: false
  param :service_id, type: :number, desc: 'Updated service ID used to derive duration and pricing when applicable', required: false
  param :starts_at, type: :string, desc: 'Updated appointment start datetime in ISO 8601 format', required: false
  param :ends_at, type: :string, desc: 'Optional updated appointment end datetime in ISO 8601 format', required: false
  param :duration_min, type: :number, desc: 'Optional updated appointment duration in minutes when ends_at is not provided', required: false
  param :appointment_type, type: :string, desc: 'Updated appointment type', required: false
  param :client_comment, type: :string, desc: 'Updated client comment', required: false
  param :custom_attributes,
        type: :object,
        desc: 'Optional scheduling custom attributes object. Use the matching list_*_custom_fields tool first; ' \
              'only returned keys are accepted, and select/multiselect values must match option.value exactly.',
        required: false

  def execute(resource_id: nil, service_id: nil, starts_at: nil, ends_at: nil, duration_min: nil, appointment_type: nil, client_comment: nil,
              custom_attributes: nil)
    appointment = appointment_operations.update_current_appointment(
      resource_id: resource_id,
      service_id: service_id,
      starts_at: starts_at,
      ends_at: ends_at,
      duration_min: duration_min,
      appointment_type: appointment_type,
      client_comment: client_comment,
      custom_attributes: custom_attributes
    )
    formatted_payload(action: 'update_appointment', appointment: ::Scheduling::PayloadBuilder.appointment(appointment))
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    current_appointment.present? && @user.present? && assistant.account.feature_enabled?('scheduling')
  end

  private

  def appointment_operations
    Captain::Tools::Operations::AppointmentOperations.new(
      assistant: assistant,
      conversation: current_conversation,
      actor: @user
    )
  end
end
