class Captain::Tools::Agent::AppointmentResult
  CONFLICT_CODES = %w[SLOT_CONFLICT APPOINTMENT_SLOT_UNAVAILABLE].freeze
  NOT_FOUND_CODES = %w[APPOINTMENT_NOT_FOUND RECORD_NOT_AVAILABLE].freeze
  VALIDATION_CODES = %w[
    VALIDATION_ERROR INVALID_IIN RESOURCE_UNAVAILABLE RESOURCE_NOT_AVAILABLE_FOR_SCHEDULING
    SERVICE_NOT_AVAILABLE_FOR_RESOURCE OUTSIDE_WORKING_HOURS BLOCKED_BY_BREAK BLOCKED_BY_HOLIDAY BLOCKED_BY_VACATION
    MEDELEMENT_CABINET_INVALID MEDELEMENT_CABINET_REQUIRED SERVICE_REQUIRED
    APPOINTMENT_READ_ONLY APPOINTMENT_SOURCE_READ_ONLY APPOINTMENT_EXTERNAL_REF_RESERVED
  ].freeze
  MAX_SEARCH_RESULTS = 20
  # A booking without service_id for a specialist who offers several services: the code of the business answer that lists them.
  SERVICE_REQUIRED_CODE = 'SERVICE_REQUIRED'.freeze
  SERVICE_REQUIRED_GUIDANCE = 'The specialist offers several services (see services). Retry with the service_id the patient asked for; ' \
                              'ask the patient when their words fit none or several.'.freeze
  SERVICE_LIST_PARTIAL = 'The list is partial: search_scheduling_services finds the others.'.freeze
  # The two answers of "nothing was changed" (the statuses of Captain::ToolResult::NO_CHANGE_STATUSES) and their result line.
  STATUS_UNCHANGED = 'unchanged'.freeze
  STATUS_ALREADY_BOOKED = 'already_booked'.freeze
  NO_CHANGE_NOTES = {
    STATUS_UNCHANGED => 'The appointment is already at %<place>s; nothing was changed.',
    STATUS_ALREADY_BOOKED => 'The appointment is already booked at %<place>s; nothing was created.'
  }.freeze
  # Message of Crm::FieldCatalog when a required custom field has no value: "custom_attributes.<key> is required".
  REQUIRED_CUSTOM_FIELD_MESSAGE = /\Acustom_attributes\.(?<key>\S+) is required\z/
  # Stable machine flag of a failed mutation: the runtime hands the conversation to a human on a technical failure and
  # lets the agent carry on after a business one (a taken slot, input the agent or the patient can correct).
  ERROR_CLASS_TECHNICAL = 'technical'.freeze
  ERROR_CLASS_BUSINESS = 'business'.freeze
  BUSINESS_REASONS = %w[time_taken not_found validation_error schedule_not_open].freeze
  TECHNICAL_INPUT_FAILURE_CODES = %w[PROVIDER_UNAVAILABLE INTERNAL_FAILURE].freeze
  PROVIDER_OPERATIONS = {
    'create_appointment' => 'create_reception',
    'update_appointment' => 'move_reception',
    'cancel_appointment' => 'remove_reception'
  }.freeze
  MOVE_GUIDANCE = {
    'pending' => 'The reschedule is only requested. The appointment is still at local_date and local_time. Do not tell the patient it was moved; ' \
                 'say the request was sent and staff will confirm the new time.',
    'needs_reconciliation' => 'The result of the reschedule is not established and staff must check it in MedElement. ' \
                              'Do not tell the patient it was moved and do not repeat the reschedule.',
    'rejected' => 'MedElement did not apply the reschedule; the appointment stays at local_date and local_time. ' \
                  'Do not tell the patient it was moved and do not repeat the reschedule on your own.'
  }.freeze
  INPUT_FAILURE_GUIDANCE = {
    'INVALID_DATE' => 'Use the exact local calendar datetime YYYY-MM-DDTHH:MM without timezone, or copy a returned ISO 8601 slot unchanged. Do not calculate UTC offsets. For an ambiguous clock use an exact returned slot.',
    'INVALID_DURATION' => 'Use a positive whole number of minutes for duration_min.',
    'INVALID_DATE_RANGE' => 'Choose an end time after the start and keep the search range within 31 days.',
    'INVALID_SERVICE_ID' => 'Use an integer service_id returned by search_scheduling_services.',
    'UNKNOWN_SERVICE' => 'Search the service catalog again and use a returned service_id.',
    'PROVIDER_UNAVAILABLE' => 'Provider availability is unknown. Ask staff to help; do not claim the slot is free or repeat an uncertain write.',
    'INTERNAL_FAILURE' => 'Scheduling could not be completed. Ask staff to help; do not repeat an uncertain provider write.'
  }.freeze

  def self.appointment(appointment, action: nil)
    resource_timezone = appointment.resource&.timezone.presence
    account_timezone = appointment.account.reporting_timezone.presence
    timezone = (ActiveSupport::TimeZone[resource_timezone] if resource_timezone) ||
               (ActiveSupport::TimeZone[account_timezone] if account_timezone) || Time.zone
    # While a reschedule is not confirmed the appointment keeps the time MedElement last confirmed (or reported by its
    # sync), so this is never the requested time; that one is reported separately by move_result.
    local_time = appointment.starts_at&.in_time_zone(timezone)
    move = Integrations::Medelement::AppointmentMoveState.read(appointment)
    status = case action
             when 'create_appointment' then 'created'
             when 'update_appointment' then 'updated'
             when 'cancel_appointment' then 'cancelled'
             else appointment.status == 'confirmed' ? 'scheduled' : appointment.status
             end
    {
      appointment_id: appointment.id,
      doctor_name: appointment.resource&.name,
      local_date: local_time&.strftime('%d.%m.%Y'),
      local_time: local_time&.strftime('%H:%M'),
      status: status
    }.merge(provider_confirmation(appointment, action: action)).merge(move_result(move, timezone)).merge(crm_link_result(appointment))
  end

  def self.move_result(move, timezone)
    return {} if move.blank?

    requested = Integrations::Medelement::AppointmentMoveState.time(move, 'requested_starts_at')&.in_time_zone(timezone)
    {
      move_state: move['state'],
      requested_local_date: requested&.strftime('%d.%m.%Y'),
      requested_local_time: requested&.strftime('%H:%M'),
      move_guidance: MOVE_GUIDANCE.fetch(move['state'])
    }.compact
  end
  private_class_method :move_result

  # The answer to an update that asked for what the appointment already has: nothing was changed, nothing was sent to the provider.
  def self.unchanged(appointment, action: nil)
    no_change(appointment, STATUS_UNCHANGED, action: action)
  end

  # The answer to a booking that exists already (the same patient, specialist and start): nothing was created. The appointment
  # keeps the confirmation state the provider gave it, so a booking that is still pending or failed is reported as that.
  def self.already_booked(appointment, action: nil)
    no_change(appointment, STATUS_ALREADY_BOOKED, action: action)
  end

  # The result line of a no-change answer: where the appointment is and with whom, in the specialist's clinic time.
  def self.no_change_note(status, facts)
    place = ["#{facts[:local_date]} #{facts[:local_time]}".strip.presence, ("with #{facts[:doctor_name]}" if facts[:doctor_name].present?)]
    format(NO_CHANGE_NOTES.fetch(status), place: place.compact.join(' '))
  end

  # The same line for the update of staff (Copilot), which answers with its own payload.
  def self.unchanged_note(appointment)
    no_change_note(STATUS_UNCHANGED, self.appointment(appointment))
  end

  def self.no_change(appointment, status, action:)
    result = success(appointment, action: action)
    return result if result[:success] == false

    result.merge(status: status, note: no_change_note(status, result))
  end
  private_class_method :no_change

  def self.success(appointment, action: nil)
    result = { success: true }.merge(self.appointment(appointment, action: action))
    return result unless PROVIDER_OPERATIONS.key?(action)

    if action == 'cancel_appointment' && Integrations::Medelement::LocalCancellation.marked?(appointment)
      return result.merge(status: 'cancelled_local_only', cancellation_scope: 'onelink_only', provider_reception_active: true,
                          provider_confirmed: false, provider_confirmation_operation: 'remove_reception', provider_confirmation_scope: 'onelink')
    end

    provider = Integrations::Medelement::AppointmentProviderStatus
    state = result[:provider_confirmation_status]
    # A reschedule MedElement has not confirmed is never a successful update, whatever the sync status of the row says
    # (a rejected move proven by read-back leaves the reception confirmed at its previous time).
    move_status = Integrations::Medelement::AppointmentMoveState.provider_status_for(result[:move_state])
    state = move_status if move_status && action == 'update_appointment'
    return result if state.blank? || state.in?([provider::SUCCEEDED, 'not_requested'])

    reason = state == provider::PENDING ? 'pending_provider_confirmation' : 'staff_will_help'
    status = case state
             when provider::PENDING then 'pending_provider_confirmation'
             when provider::UNKNOWN then provider::UNKNOWN
             else 'provider_confirmation_failed'
             end
    result.merge(success: false, reason: reason, status: status, provider_confirmation_status: state, provider_confirmed: false,
                 error_class: ERROR_CLASS_TECHNICAL)
  end

  # The result of a mutation MedElement did not confirm (rejected, failed, unknown or no answer in time): the appointment keeps
  # what the calendar knows and the tool reports a technical failure whatever the stored provider status says.
  def self.provider_failure(appointment, action:)
    result = success(appointment, action: action)
    return result if result[:success] == false

    result.merge(
      success: false, reason: 'staff_will_help', status: 'provider_confirmation_failed', provider_confirmed: false,
      provider_confirmation_operation: PROVIDER_OPERATIONS[action], provider_confirmation_scope: 'medelement',
      error_class: ERROR_CLASS_TECHNICAL
    ).compact
  end

  def self.provider_confirmation(appointment, action: nil)
    provider = Integrations::Medelement::AppointmentProviderStatus
    payload = provider.payload(appointment)
    operation = PROVIDER_OPERATIONS[action]
    return payload if operation.blank? || (appointment.status == 'cancelled' && Integrations::Medelement::LocalCancellation.marked?(appointment))

    receipt = appointment.medelement_provider_command_receipt
    if receipt.present? && receipt.operation == operation
      state = if receipt.succeeded?
                payload[:provider_confirmed] && payload[:provider_confirmation_operation].in?([nil, operation]) &&
                  provider.bound_to_command?(appointment, receipt) ? provider::SUCCEEDED : 'not_confirmed'
              elsif receipt.provider_status_unknown?
                provider::UNKNOWN
              elsif receipt.terminal?
                provider::FAILED
              else
                provider::PENDING
              end
      return { provider_confirmation_status: state, provider_confirmed: state == provider::SUCCEEDED,
               provider_confirmation_operation: operation, provider_confirmation_scope: 'medelement' }
    end
    return payload if payload.blank?

    if payload[:provider_confirmation_operation].present? && payload[:provider_confirmation_operation] != operation
      return { provider_confirmation_status: 'not_requested', provider_confirmed: false,
               provider_confirmation_operation: operation, provider_confirmation_scope: 'medelement' }
    end
    payload.merge(provider_confirmation_operation: operation).tap do |result|
      if result[:provider_confirmed] && payload[:provider_confirmation_operation].blank?
        result[:provider_confirmed] = false
        result[:provider_confirmation_status] = 'not_confirmed'
      end
    end
  end
  private_class_method :provider_confirmation

  def self.crm_link_result(appointment)
    warning = appointment.custom_attributes.to_h['crm_link_result']
    return {} unless warning.is_a?(Hash) && warning['status'] == 'not_linked'

    { crm_link_result: warning.slice('status', 'code', 'message', 'details'),
      crm_link_guidance: 'The appointment is saved. Do not create it again to fix the deal link. Staff can link this appointment after resolving the CRM fields.' }
  end
  private_class_method :crm_link_result

  def self.failure_output(error, account: nil)
    result = failure(error, account: account)
    audit = result.delete(:audit)
    return JSON.generate(result) unless audit

    # The correction is the error text of the result; the data next to it does not say it a second time.
    Captain::ToolResult.failure(error: result[:correction], data: result.except(:correction).deep_stringify_keys, retryable: false,
                                audit: audit.merge(error_class: result[:error_class]))
  end

  def self.input_failure_class(code)
    TECHNICAL_INPUT_FAILURE_CODES.include?(code) ? ERROR_CLASS_TECHNICAL : ERROR_CLASS_BUSINESS
  end
  private_class_method :input_failure_class

  # A required appointment field (a custom field the clinic marked as required) that the booking did not carry: the agent fixes it by
  # asking the patient. The failure names the field by its label, never by an id, and nothing was written before it.
  def self.required_custom_field_failure(error, account)
    return unless error.is_a?(::Crm::Error) && error.code.to_s == 'VALIDATION_ERROR'

    key = error.message.to_s[REQUIRED_CUSTOM_FIELD_MESSAGE, :key]
    return if key.blank?

    label = required_custom_field_label(account, key)
    { success: false, reason: 'validation_error', code: 'CUSTOM_FIELD_REQUIRED', error_class: ERROR_CLASS_BUSINESS,
      correction: "Required appointment field \"#{label}\" is missing. Ask the patient for it, then retry with its value in " \
                  'custom_attributes (keys: list_appointment_custom_fields).',
      audit: { mutation_executed: false, failure_stage: 'tool_arguments' } }
  end
  private_class_method :required_custom_field_failure

  def self.required_custom_field_label(account, key)
    definition = account&.crm_field_definitions&.active&.for_entity_kind('appointment')&.find_by(key: key)
    definition&.label.presence || key
  end
  private_class_method :required_custom_field_label

  # A booking with no service_id for a specialist who offers several: the agent chooses by the patient's words or asks the patient.
  # The failure lists the services by ID and name; nothing was written before it.
  def self.service_required_failure(error)
    return unless error.is_a?(::Scheduling::Error) && error.code.to_s == SERVICE_REQUIRED_CODE

    details = error.details.to_h.with_indifferent_access
    partial = details[:more].to_i.positive?
    { success: false, reason: 'validation_error', code: SERVICE_REQUIRED_CODE, error_class: ERROR_CLASS_BUSINESS,
      services: Array(details[:services]), more_services: (details[:more].to_i if partial),
      correction: partial ? "#{SERVICE_REQUIRED_GUIDANCE} #{SERVICE_LIST_PARTIAL}" : SERVICE_REQUIRED_GUIDANCE,
      audit: { mutation_executed: false, failure_stage: 'tool_arguments' } }.compact
  end
  private_class_method :service_required_failure

  def self.failure(error, account: nil)
    answer = required_custom_field_failure(error, account) || service_required_failure(error)
    return answer if answer

    code = error.respond_to?(:code) ? error.code.to_s : ''
    if code.blank? && !error.is_a?(ArgumentError) && !error.is_a?(ActiveRecord::RecordInvalid) && !error.is_a?(ActiveRecord::RecordNotFound)
      code = 'INTERNAL_FAILURE'
    end
    if error.is_a?(Scheduling::Error) && code == 'MEDELEMENT_AVAILABILITY_UNVERIFIED'
      cause = error.details.to_h.with_indifferent_access[:provider_reason]
      code = cause == 'internal_failure' ? 'INTERNAL_FAILURE' : 'PROVIDER_UNAVAILABLE' if cause.present?
    end
    if INPUT_FAILURE_GUIDANCE.key?(code)
      result = { success: false, reason: code.downcase, code: code, correction: INPUT_FAILURE_GUIDANCE.fetch(code),
                 error_class: input_failure_class(code) }
      if error.is_a?(Scheduling::Error) && error.details.to_h.with_indifferent_access[:mutation_executed] == false
        result[:audit] = { mutation_executed: false, failure_stage: 'tool_arguments' }
      end
      return result
    end
    reason = if code == 'MEDELEMENT_HORIZON_EXCEEDED'
               'schedule_not_open'
             elsif CONFLICT_CODES.include?(code)
               'time_taken'
             elsif NOT_FOUND_CODES.include?(code) || error.is_a?(ActiveRecord::RecordNotFound) ||
                   error.message.in?(['Record is not available', 'Appointment is not available for the current conversation'])
               'not_found'
             elsif VALIDATION_CODES.include?(code) || error.is_a?(ArgumentError) || error.is_a?(ActiveRecord::RecordInvalid)
               'validation_error'
             else
               'staff_will_help'
             end
    result = { success: false, reason: reason, error_class: (BUSINESS_REASONS.include?(reason) ? ERROR_CLASS_BUSINESS : ERROR_CLASS_TECHNICAL) }
    if reason == 'schedule_not_open'
      date = error.details.to_h.with_indifferent_access[:last_available_date]
      result[:last_available_date] = date if date.present?
    end
    result
  end
end
