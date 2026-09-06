class Captain::Tools::Copilot::CreateAppointmentService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'create_appointment'
  end

  description 'Create an appointment for the current conversation contact using a selected specialist and confirmed time details. ' \
              'For provider-backed appointments, pending_provider_confirmation is not a confirmed booking; do not tell the patient ' \
              'they are booked until provider_confirmed is true.'
  param :resource_id, type: :number, desc: 'Specialist resource ID', required: true
  param :starts_at, type: :string, desc: 'Appointment start datetime in ISO 8601 format', required: true
  param :ends_at, type: :string, desc: 'Optional appointment end datetime in ISO 8601 format', required: false
  param :duration_min, type: :number, desc: 'Optional appointment duration in minutes when ends_at is not provided', required: false
  param :service_id, type: :number, desc: 'Optional local service ID returned by search_scheduling_services', required: false
  param :appointment_type,
        type: :string,
        desc: 'Appointment type: primary, secondary, or other. Do not pass a specialty, service, or cabinet name.',
        required: false
  param :client_comment, type: :string, desc: 'Client comment', required: false
  param :custom_attributes,
        type: :object,
        desc: 'Optional scheduling custom attributes object. For Medelement, pass the selected ' \
              'resource.custom_attributes.medelement_cabinets[].companyCabinetCode as medelement_cabinet_code. For other keys, use the matching ' \
              'list_*_custom_fields tool first; only returned keys are accepted, and select/multiselect values must match option.value exactly.',
        required: false

  def execute(resource_id:, starts_at:, ends_at: nil, duration_min: nil, service_id: nil, appointment_type: nil, client_comment: nil,
              custom_attributes: nil)
    appointment = appointment_operations.create_appointment(
      resource_id: resource_id,
      service_id: service_id,
      starts_at: starts_at,
      ends_at: ends_at,
      duration_min: duration_min,
      appointment_type: appointment_type,
      client_comment: client_comment,
      custom_attributes: custom_attributes
    )
    formatted_payload(
      ::Scheduling::ToolPayloadBuilder.appointment_payload(action: 'create_appointment', appointment: appointment)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
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
