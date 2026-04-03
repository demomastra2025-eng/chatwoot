class Captain::Tools::Operations::AppointmentOperations < Captain::Tools::Operations::BaseOperation
  def cancel_current_appointment
    ensure_feature_enabled!('scheduling', 'Scheduling is not enabled for this account')
    raise ArgumentError, 'Current appointment is not available' if current_appointment.blank?

    ::Scheduling::Appointments::UpsertService.new(
      account: account,
      params: {
        status: 'cancelled',
        payment_status: 'cancelled'
      },
      appointment: current_appointment,
      actor: actor
    ).perform
  end

  def create_appointment(resource_id:, starts_at:, ends_at:, service_id: nil, appointment_type: nil, client_comment: nil, custom_attributes: nil)
    ensure_feature_enabled!('scheduling', 'Scheduling is not enabled for this account')

    create_params = {
      resource_id: resource_id,
      service_id: service_id,
      starts_at: starts_at,
      ends_at: ends_at,
      appointment_type: appointment_type,
      client_comment: client_comment,
      contact_id: current_contact&.id,
      company_id: current_company&.id,
      conversation_id: conversation&.id,
      created_by_id: actor&.id,
      custom_attributes: parsed_hash(custom_attributes, field_name: 'custom_attributes')
    }.compact

    with_idempotent_creation('create_appointment', create_params) do
      ::Scheduling::Appointments::UpsertService.new(
        account: account,
        params: create_params,
        actor: actor
      ).perform
    end
  end

  def update_current_appointment(resource_id: nil, service_id: nil, starts_at: nil, ends_at: nil, appointment_type: nil, client_comment: nil, custom_attributes: nil)
    ensure_feature_enabled!('scheduling', 'Scheduling is not enabled for this account')
    raise ArgumentError, 'Current appointment is not available' if current_appointment.blank?

    params = {}
    params[:resource_id] = resource_id if !resource_id.nil?
    params[:service_id] = service_id if !service_id.nil?
    params[:starts_at] = starts_at if !starts_at.nil?
    params[:ends_at] = ends_at if !ends_at.nil?
    params[:appointment_type] = appointment_type if !appointment_type.nil?
    params[:client_comment] = client_comment if !client_comment.nil?
    params[:custom_attributes] = parsed_hash(custom_attributes, field_name: 'custom_attributes') if custom_attributes.present?

    ::Scheduling::Appointments::UpsertService.new(
      account: account,
      params: params,
      appointment: current_appointment,
      actor: actor
    ).perform
  end
end
