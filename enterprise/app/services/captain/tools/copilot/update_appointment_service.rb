class Captain::Tools::Copilot::UpdateAppointmentService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'update_appointment'
  end

  description 'Update the appointment linked to the current conversation'
  param :resource_id, type: :number, desc: 'Updated specialist resource ID', required: false
  param :service_id, type: :number, desc: 'Updated service ID', required: false
  param :starts_at, type: :string, desc: 'Updated appointment start datetime', required: false
  param :ends_at, type: :string, desc: 'Updated appointment end datetime', required: false
  param :appointment_type, type: :string, desc: 'Updated appointment type', required: false
  param :client_comment, type: :string, desc: 'Updated client comment', required: false
  param :custom_attributes_json, type: :string, desc: 'Optional custom attributes as JSON object', required: false

  def execute(resource_id: nil, service_id: nil, starts_at: nil, ends_at: nil, appointment_type: nil, client_comment: nil, custom_attributes_json: nil)
    appointment = appointment_operations.update_current_appointment(
      resource_id: resource_id,
      service_id: service_id,
      starts_at: starts_at,
      ends_at: ends_at,
      appointment_type: appointment_type,
      client_comment: client_comment,
      custom_attributes: custom_attributes_json
    )
    formatted_record(appointment)
  rescue StandardError => e
    e.message
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
