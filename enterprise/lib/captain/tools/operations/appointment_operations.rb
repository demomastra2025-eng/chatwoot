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

  def create_appointment(resource_id:, starts_at:, ends_at: nil, duration_min: nil, service_id: nil, appointment_type: nil, client_comment: nil,
                         custom_attributes: nil)
    ensure_feature_enabled!('scheduling', 'Scheduling is not enabled for this account')

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
        actor: actor
      ).perform
    end
    attach_provider_command_receipt(appointment)
  end

  def update_current_appointment(resource_id: nil, service_id: nil, starts_at: nil, ends_at: nil, duration_min: nil, appointment_type: nil,
                                 client_comment: nil, custom_attributes: nil)
    ensure_feature_enabled!('scheduling', 'Scheduling is not enabled for this account')
    raise ArgumentError, 'Current appointment is not available' if current_appointment.blank?

    params = {}
    params[:resource_id] = resource_id unless resource_id.nil?
    params[:service_id] = service_id unless service_id.nil?
    params[:starts_at] = starts_at unless starts_at.nil?
    params[:ends_at] = ends_at unless ends_at.nil?
    params[:duration_min] = duration_min unless duration_min.nil?
    params[:appointment_type] = appointment_type unless appointment_type.nil?
    params[:client_comment] = client_comment unless client_comment.nil?
    params[:custom_attributes] = parsed_hash(custom_attributes, field_name: 'custom_attributes') if custom_attributes.present?

    ::Scheduling::Appointments::UpsertService.new(
      account: account,
      params: params,
      appointment: current_appointment,
      actor: actor
    ).perform
  end

  def add_payment_to_current_appointment(payment_method:, amount: nil)
    ensure_feature_enabled!('scheduling', 'Scheduling is not enabled for this account')
    ensure_feature_enabled!('scheduling_finance', 'Scheduling finance is not enabled for this account')
    raise ArgumentError, 'Current appointment is not available' if current_appointment.blank?
    raise ArgumentError, 'payment_method is required' if payment_method.blank?

    ::Scheduling::Appointments::FinanceSyncService.new(
      appointment: current_appointment,
      actor: actor
    ).add_payment!(
      amount: amount,
      payment_method: payment_method
    )
  end

  private

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
end
