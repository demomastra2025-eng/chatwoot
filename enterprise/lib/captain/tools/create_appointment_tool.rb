class Captain::Tools::CreateAppointmentTool < Captain::Tools::BasePublicTool
  description 'Create an appointment for the current conversation contact using a selected specialist and confirmed time details. ' \
              'A successful result for a Medelement-linked specialist includes a reception ID from this booking command: ' \
              'confirm the booking to the patient in your reply. For a local-only booking, the local calendar save is sufficient. ' \
              'If the tool reports failure or an unknown outcome, do not claim success or repeat the create call; ' \
              'use the handoff tool when available.'
  param :resource_id, type: 'number', desc: 'Specialist resource ID', required: true
  param :starts_at, type: 'string', desc: 'Appointment start datetime in ISO 8601 format', required: true
  param :ends_at, type: 'string', desc: 'Optional appointment end datetime in ISO 8601 format', required: false
  param :duration_min, type: 'number', desc: 'Optional appointment duration in minutes when ends_at is not provided', required: false
  param :service_id, type: 'number', desc: 'Optional local service ID returned by search_scheduling_services', required: false
  param :appointment_type,
        type: 'string',
        desc: 'Appointment type: primary, secondary, or other. Do not pass a specialty, service, or cabinet name.',
        required: false
  param :client_comment, type: 'string', desc: 'Client comment', required: false
  param :custom_attributes,
        type: 'object',
        desc: 'Optional scheduling custom attributes object. For Medelement, pass the selected ' \
              'resource.custom_attributes.medelement_cabinets[].companyCabinetCode as medelement_cabinet_code. For other keys, use the matching ' \
              'list_*_custom_fields tool first; only returned keys are accepted, and select/multiselect values must match option.value exactly.',
        required: false

  # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists
  def perform(tool_context, resource_id:, starts_at:, ends_at: nil, duration_min: nil, service_id: nil, appointment_type: nil, client_comment: nil,
              custom_attributes: nil)
    operation = operations(tool_context.state)
    appointment = operation.create_appointment(
      resource_id: resource_id,
      service_id: service_id,
      starts_at: starts_at,
      ends_at: ends_at,
      duration_min: duration_min,
      appointment_type: appointment_type,
      client_comment: client_comment,
      custom_attributes: custom_attributes
    )

    command = verify_provider_booking!(tool_context, appointment)
    JSON.generate(Captain::Tools::Agent::AppointmentResult.success(appointment, action: 'create_appointment'))
  rescue Scheduling::Error => e
    appointment ||= operation.persisted_creation if operation.respond_to?(:persisted_creation)
    handoff_unconfirmed_booking!(tool_context, appointment, e)
    JSON.generate(Captain::Tools::Agent::AppointmentResult.failure(e))
  rescue StandardError => e
    appointment ||= operation.persisted_creation if operation.respond_to?(:persisted_creation)
    handle_unexpected_booking_error(tool_context, appointment, command, e)
  end
  # rubocop:enable Metrics/MethodLength, Metrics/ParameterLists

  private

  def verify_provider_booking!(tool_context, appointment)
    Captain::Tools::ProviderBookingOutcomeService.new(
      appointment: appointment, assistant: assistant, response_fence: tool_context.state[:captain_response_fence]
    ).perform
  end

  def handoff_unconfirmed_booking!(tool_context, appointment, error)
    return if appointment.blank?
    return unless provider_booking_failure?(appointment, error)

    Captain::Tools::ProviderBookingHandoffService.new(
      assistant: assistant, conversation: current_conversation(tool_context.state), appointment: appointment,
      command: appointment&.medelement_provider_command_receipt,
      fence: tool_context.state[:captain_response_fence],
      orphaned_write: error.is_a?(Scheduling::Error) && error.code == 'MEDELEMENT_BOOKING_SUPERSEDED'
    ).perform
  end

  def provider_booking_failure?(appointment, error)
    if error.is_a?(Scheduling::Error)
      return error.code.in?(%w[MEDELEMENT_COMMAND_RECEIPT_UNAVAILABLE MEDELEMENT_BOOKING_UNKNOWN MEDELEMENT_BOOKING_FAILED
                               MEDELEMENT_BOOKING_SUPERSEDED])
    end

    appointment.custom_attributes.to_h[Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY].present?
  end

  def handle_unexpected_booking_error(tool_context, appointment, command, error)
    handoff_unconfirmed_booking!(tool_context, appointment, error) if command.nil?
    JSON.generate(Captain::Tools::Agent::AppointmentResult.failure(error))
  end

  def operations(state)
    Captain::Tools::Operations::AppointmentOperations.new(
      assistant: assistant,
      conversation: current_conversation(state),
      actor: assistant
    )
  end
end
