class Captain::Tools::CreateAppointmentTool < Captain::Tools::BasePublicTool
  description 'Create an appointment using a selected specialist and confirmed time details. ' \
              'For a named relative or another patient, pass their explicit patient details; the communication chat stays unchanged. ' \
              'A successful result for a Medelement-linked specialist includes a reception ID from this booking command: ' \
              'confirm the booking to the patient in your reply. For a local-only booking, the local calendar save is sufficient. ' \
              'For an argument validation failure follow the returned correction before retrying. ' \
              'For any other failure or an unknown outcome, do not claim success or repeat the create call; ' \
              'use the handoff tool when available. Report the local_date and local_time returned by the tool, never substitute the requested time.'
  param :resource_id, type: 'number', desc: 'Specialist resource ID', required: true
  param :starts_at, type: 'string', desc: 'Use the exact requested local calendar clock as YYYY-MM-DDTHH:MM without a timezone; the server resolves the specialist timezone. ' \
              'Do not convert it to UTC yourself. Alternatively copy an ISO 8601 datetime returned by a slot tool unchanged.', required: true
  param :ends_at, type: 'string', desc: 'Optional local calendar end YYYY-MM-DDTHH:MM without timezone, or exact returned slot datetime. Prefer duration_min; do not calculate timezone offsets.', required: false
  param :duration_min, type: 'number', desc: 'Optional appointment duration in minutes when ends_at is not provided', required: false
  param :service_id, type: 'number', desc: 'Optional local service ID returned by search_scheduling_services', required: false
  param :appointment_type,
        type: 'string',
        desc: 'Appointment type: primary, secondary, or other. Do not pass a specialty, service, or cabinet name.',
        required: false
  param :client_comment, type: 'string', desc: 'Client comment', required: false
  param :crm_deal_id, type: 'number', desc: 'Optional existing deal ID returned by search_deals for this conversation contact', required: false
  param :crm_pipeline_id, type: 'number', desc: 'Optional pipeline ID when a new deal should be created according to its appointment settings', required: false
  param :patient, type: 'object', required: false,
                  desc: 'Optional explicitly named patient: first_name and last_name required; middle_name, iin, birth_date (YYYY-MM-DD), ' \
                        'gender and phone optional. Ask for missing details; do not copy the caller identity to another patient.'
  param :custom_attributes,
        type: 'object',
        desc: 'Optional scheduling custom attributes object. For Medelement, pass the selected ' \
              'resource.custom_attributes.medelement_cabinets[].companyCabinetCode as medelement_cabinet_code. For other keys, use the matching ' \
              'list_*_custom_fields tool first; only returned keys are accepted, and select/multiselect values must match option.value exactly.',
        required: false

  # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists
  def perform(tool_context, resource_id:, starts_at:, ends_at: nil, duration_min: nil, service_id: nil, appointment_type: nil, client_comment: nil,
              custom_attributes: nil, patient: nil, crm_deal_id: nil, crm_pipeline_id: nil)
    operation = operations(tool_context.state)
    appointment = operation.create_appointment(
      resource_id: resource_id,
      service_id: service_id,
      starts_at: starts_at,
      ends_at: ends_at,
      duration_min: duration_min,
      appointment_type: appointment_type,
      client_comment: client_comment,
      custom_attributes: custom_attributes,
      patient: patient,
      crm_deal_id: crm_deal_id,
      crm_pipeline_id: crm_pipeline_id
    )

    command = verify_provider_booking!(tool_context, appointment)
    JSON.generate(booking_result(appointment, command))
  rescue Scheduling::Error => e
    appointment ||= operation.persisted_creation if operation.respond_to?(:persisted_creation)
    handoff_unconfirmed_booking!(tool_context, appointment, e)
    Captain::Tools::Agent::AppointmentResult.failure_output(e)
  rescue StandardError => e
    appointment ||= operation.persisted_creation if operation.respond_to?(:persisted_creation)
    handle_unexpected_booking_error(tool_context, appointment, command, e)
  end
  # rubocop:enable Metrics/MethodLength, Metrics/ParameterLists

  private

  def booking_result(appointment, verified_command)
    result = Captain::Tools::Agent::AppointmentResult.success(appointment, action: 'create_appointment')
    return result unless verified_command

    # OutcomeService has verified this exact current write's reception ID. Its
    # asynchronous read-back may still be pending; that must not undo success.
    result.merge(
      success: true, status: 'created', provider_confirmed: true,
      provider_confirmation_status: Integrations::Medelement::AppointmentProviderStatus::SUCCEEDED,
      provider_confirmation_operation: 'create_reception', provider_confirmation_scope: 'medelement'
    ).except(:reason)
  end

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
    Captain::Tools::Agent::AppointmentResult.failure_output(error)
  end

  def operations(state)
    Captain::Tools::Operations::AppointmentOperations.new(
      assistant: assistant,
      conversation: current_conversation(state),
      actor: assistant
    )
  end
end
