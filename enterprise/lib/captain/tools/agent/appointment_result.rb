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
    }
  end

  def self.success(appointment, action: nil)
    result = { success: true }.merge(self.appointment(appointment, action: action))
    return result unless action.in?(%w[update_appointment cancel_appointment])

    if action == 'cancel_appointment' && Integrations::Medelement::LocalCancellation.marked?(appointment)
      return result.merge(status: 'cancelled_local_only', cancellation_scope: 'onelink_only', provider_reception_active: true)
    end

    provider = Integrations::Medelement::AppointmentProviderStatus
    state = appointment.custom_attributes.to_h[provider::ATTRIBUTE_KEY]
    return result if state.blank? || state == provider::SUCCEEDED

    reason = state == provider::PENDING ? 'pending_provider_confirmation' : 'staff_will_help'
    result.merge(success: false, reason: reason, status: provider.public_status(appointment), provider_confirmed: false)
  end

  def self.failure(error)
    code = error.respond_to?(:code) ? error.code.to_s : ''
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
