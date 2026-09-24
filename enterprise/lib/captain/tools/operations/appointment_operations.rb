class Captain::Tools::Operations::AppointmentOperations < Captain::Tools::Operations::BaseOperation
  def cancel_current_appointment(appointment_id: nil)
    ensure_feature_enabled!('scheduling', 'Scheduling is not enabled for this account')
    appointment = target_appointment(appointment_id)

    authorize_appointment!(appointment, :transition?)

    ::Scheduling::Appointments::CancelService.new(
      appointment: appointment,
      actor: actor
    ).perform
  end

  def create_appointment(resource_id:, starts_at:, ends_at: nil, duration_min: nil, service_id: nil, appointment_type: nil, client_comment: nil,
                         custom_attributes: nil)
    ensure_feature_enabled!('scheduling', 'Scheduling is not enabled for this account')
    authorize_appointment!(::Scheduling::Appointment, :create?)

    create_params = {
      resource_id: resource_id,
      service_id: service_id,
      starts_at: starts_at,
      ends_at: ends_at,
      duration_min: duration_min,
      appointment_type: appointment_type,
      client_comment: client_comment,
      contact_id: current_contact&.id,
      company_id: current_company&.id,
      conversation_id: conversation&.id,
      created_by_id: (actor.id if actor.is_a?(User)),
      custom_attributes: parsed_hash(custom_attributes, field_name: 'custom_attributes')
    }.compact

    appointment = with_idempotent_creation('create_appointment', create_params) do
      ::Scheduling::Appointments::UpsertService.new(
        account: account,
        params: create_params,
        actor: actor,
        required_capabilities: ['create']
      ).perform
    end
    attach_provider_command_receipt(appointment)
  end

  def update_current_appointment(appointment_id: nil, resource_id: nil, service_id: nil, starts_at: nil, ends_at: nil, duration_min: nil,
                                 appointment_type: nil, client_comment: nil, custom_attributes: nil)
    ensure_feature_enabled!('scheduling', 'Scheduling is not enabled for this account')
    appointment = target_appointment(appointment_id)

    params = {}
    params[:resource_id] = resource_id unless resource_id.nil?
    params[:service_id] = service_id unless service_id.nil?
    params[:starts_at] = starts_at unless starts_at.nil?
    params[:ends_at] = ends_at unless ends_at.nil?
    params[:duration_min] = duration_min unless duration_min.nil?
    params[:appointment_type] = appointment_type unless appointment_type.nil?
    params[:client_comment] = client_comment unless client_comment.nil?
    params[:custom_attributes] = parsed_hash(custom_attributes, field_name: 'custom_attributes') if custom_attributes.present?

    authorize_appointment_update!(appointment, params)

    ::Scheduling::Appointments::UpsertService.new(
      account: account,
      params: params,
      appointment: appointment,
      actor: actor,
      required_capabilities: appointment_update_capabilities(params)
    ).perform
  end


  private

  def target_appointment(appointment_id)
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?

    if appointment_id.nil? && current_appointment.present?
      return current_appointment if current_appointment.account_id == account.id

      raise ArgumentError, 'Current appointment is not available'
    end

    appointments = account.scheduling_appointments.where(conversation_id: conversation.id)
    return explicit_target_appointment(appointments, appointment_id) unless appointment_id.nil?

    compatible_appointments = appointments.limit(2).to_a
    raise ArgumentError, 'Current appointment is not available' if compatible_appointments.empty?
    raise ArgumentError, 'appointment_id is required when the conversation has multiple appointments' if compatible_appointments.many?

    compatible_appointments.first
  end

  def explicit_target_appointment(appointments, appointment_id)
    appointment_id = required_positive_id(appointment_id, field_name: 'appointment_id')
    appointment = appointments.find_by(id: appointment_id)
    raise ArgumentError, 'Appointment is not available for the current conversation' if appointment.blank?

    appointment
  end

  def attach_provider_command_receipt(appointment)
    return appointment if appointment.medelement_provider_command_receipt.present?
    return appointment if appointment.resource&.custom_attributes.to_h['medelement_specialist_code'].blank?

    Integrations::Medelement::AppointmentProviderCommandReceiptLookupService.new(
      account: account,
      appointment: appointment,
      operation: 'create_reception'
    ).perform
    appointment
  end

  def authorize_appointment_update!(appointment, params)
    authorize_appointment!(appointment, :assign?) if params.key?(:resource_id)
    authorize_appointment!(appointment, :update?) if appointment_update_fields?(params)
  end

  def appointment_update_capabilities(params)
    appointment_update_fields?(params) ? ['update_fields'] : []
  end

  def appointment_update_fields?(params)
    (params.keys - [:resource_id]).any?
  end

  def authorize_appointment!(appointment, query)
    return if actor.blank? || customer_agent_execution?

    user_context = {
      user: actor,
      account: account,
      account_user: account.account_users.find_by(user_id: actor&.id)
    }
    return if ::Scheduling::AppointmentPolicy.new(user_context, appointment).public_send(query)

    raise Pundit::NotAuthorizedError, 'You are not authorized to access this appointment'
  end
end
