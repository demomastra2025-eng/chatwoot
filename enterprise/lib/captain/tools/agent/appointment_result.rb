class Captain::Tools::Agent::AppointmentResult
  CONFLICT_CODES = %w[SLOT_CONFLICT APPOINTMENT_SLOT_UNAVAILABLE].freeze
  NOT_FOUND_CODES = %w[APPOINTMENT_NOT_FOUND RECORD_NOT_AVAILABLE].freeze
  VALIDATION_CODES = %w[
    VALIDATION_ERROR INVALID_IIN RESOURCE_UNAVAILABLE RESOURCE_NOT_AVAILABLE_FOR_SCHEDULING
    SERVICE_NOT_AVAILABLE_FOR_RESOURCE OUTSIDE_WORKING_HOURS BLOCKED_BY_BREAK BLOCKED_BY_HOLIDAY BLOCKED_BY_VACATION
    MEDELEMENT_CABINET_INVALID MEDELEMENT_CABINET_REQUIRED
    APPOINTMENT_READ_ONLY APPOINTMENT_SOURCE_READ_ONLY APPOINTMENT_EXTERNAL_REF_RESERVED
  ].freeze
  MAX_SEARCH_RESULTS = 20
  PROVIDER_OPERATIONS = {
    'create_appointment' => 'create_reception',
    'update_appointment' => 'move_reception',
    'cancel_appointment' => 'remove_reception'
  }.freeze
  INPUT_FAILURE_GUIDANCE = {
    'INVALID_DATE' => 'Use a valid ISO 8601 date/time for the requested field.',
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
    local_time = appointment.starts_at&.in_time_zone(timezone)
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
    }.merge(provider_confirmation(appointment, action: action))
  end

  def self.success(appointment, action: nil)
    result = { success: true }.merge(self.appointment(appointment, action: action))
    return result unless PROVIDER_OPERATIONS.key?(action)

    if action == 'cancel_appointment' && Integrations::Medelement::LocalCancellation.marked?(appointment)
      return result.merge(status: 'cancelled_local_only', cancellation_scope: 'onelink_only', provider_reception_active: true,
                          provider_confirmed: false, provider_confirmation_operation: 'remove_reception', provider_confirmation_scope: 'onelink')
    end

    provider = Integrations::Medelement::AppointmentProviderStatus
    state = result[:provider_confirmation_status]
    return result if state.blank? || state.in?([provider::SUCCEEDED, 'not_requested'])

    reason = state == provider::PENDING ? 'pending_provider_confirmation' : 'staff_will_help'
    status = case state
             when provider::PENDING then 'pending_provider_confirmation'
             when provider::UNKNOWN then provider::UNKNOWN
             else 'provider_confirmation_failed'
             end
    result.merge(success: false, reason: reason, status: status, provider_confirmed: false)
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

  def self.failure(error)
    code = error.respond_to?(:code) ? error.code.to_s : ''
    if code.blank? && !error.is_a?(ArgumentError) && !error.is_a?(ActiveRecord::RecordInvalid) && !error.is_a?(ActiveRecord::RecordNotFound)
      code = 'INTERNAL_FAILURE'
    end
    if error.is_a?(Scheduling::Error) && code == 'MEDELEMENT_AVAILABILITY_UNVERIFIED'
      cause = error.details.to_h.with_indifferent_access[:provider_reason]
      code = cause == 'internal_failure' ? 'INTERNAL_FAILURE' : 'PROVIDER_UNAVAILABLE' if cause.present?
    end
    if INPUT_FAILURE_GUIDANCE.key?(code)
      return { success: false, reason: code.downcase, code: code, correction: INPUT_FAILURE_GUIDANCE.fetch(code) }
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
    result = { success: false, reason: reason }
    if reason == 'schedule_not_open'
      date = error.details.to_h.with_indifferent_access[:last_available_date]
      result[:last_available_date] = date if date.present?
    end
    result
  end
end
