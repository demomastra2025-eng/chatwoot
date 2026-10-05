class Captain::Tools::Operations::AppointmentOperations < Captain::Tools::Operations::BaseOperation
  attr_reader :persisted_creation

  def cancel_current_appointment(appointment_id: nil)
    ensure_feature_enabled!('scheduling', 'Scheduling is not enabled for this account')
    appointment = target_appointment(appointment_id)
    # Imported MedElement receptions stay read-only for Captain.
    ::Scheduling::Appointments::MutationGuard.ensure_editable!(appointment)

    # The same provider-aware path as staff: a verified MedElement booking is
    # removed through a remove command, an unverified one fails with a typed error.
    ::Scheduling::Appointments::CancelService.new(appointment: appointment, actor: actor).perform
  end

  def create_appointment(resource_id:, starts_at:, ends_at: nil, duration_min: nil, service_id: nil, appointment_type: nil, client_comment: nil,
                         custom_attributes: nil)
    @persisted_creation = nil
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

    persist_creation!(create_params)
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

    ::Scheduling::Appointments::UpsertService.new(
      account: account,
      params: params,
      appointment: appointment,
      actor: actor
    ).perform
  end

  private

  def persist_creation!(create_params)
    upsert = nil
    appointment = with_idempotent_creation('create_appointment', create_params) do
      upsert = ::Scheduling::Appointments::UpsertService.new(account: account, params: create_params, actor: actor)
      upsert.perform
    end
    @persisted_creation = appointment
    attach_provider_command_receipt(appointment)
  rescue StandardError
    @persisted_creation ||= upsert&.persisted_appointment
    cache_persisted_creation!(create_params) if @persisted_creation
    raise
  end

  def cache_persisted_creation!(create_params)
    Captain::ToolExecutionIdempotency.store_record(
      assistant: assistant, tool_id: 'create_appointment', params: create_params,
      scope: idempotency_scope, record: persisted_creation
    )
  end

  def target_appointment(appointment_id)
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?

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
end
