class Captain::Tools::Operations::AppointmentOperations < Captain::Tools::Operations::BaseOperation
  SERVICE_OMITTED = Object.new.freeze
  # persisted_creation: the appointment a create call saved. unchanged_appointment: the appointment an update call found already
  # in the state it asked for (nothing was sent to the provider and nothing was saved). already_booked_appointment: the appointment
  # a create call of the agent found booked already for the same patient, specialist and start (nothing was created).
  attr_reader :persisted_creation, :unchanged_appointment, :already_booked_appointment

  # The fields of an update that can be compared with the appointment (a custom attribute cannot, so it is always a change).
  UNCHANGED_INTEGER_FIELDS = %i[resource_id service_id duration_min].freeze
  UNCHANGED_TIME_FIELDS = %i[starts_at ends_at].freeze
  UNCHANGED_TEXT_FIELDS = %i[appointment_type client_comment].freeze
  # A start before now (see #ensure_future_start!): "Monday 2026-10-26 14:05" in the clinic's clock.
  START_IN_PAST_CODE = Captain::Tools::Agent::AppointmentResult::START_IN_PAST_CODE
  START_LABEL_FORMAT = '%A %Y-%m-%d %H:%M'.freeze

  def cancel_current_appointment(appointment_id: nil, appointment_access_token: nil, patient_confirmed: false)
    ensure_feature_enabled!('scheduling', 'Scheduling is not enabled for this account')
    appointment = target_appointment(appointment_id, appointment_access_token: appointment_access_token, patient_confirmed: patient_confirmed)
    if imported_appointment?(appointment)
      return mutate_imported_appointment(appointment, 'remove_reception', {}, appointment_access_token, patient_confirmed)
    end

    # The same provider-aware path as staff: a verified MedElement booking is
    # removed through a remove command, an unverified one fails with a typed error.
    ::Scheduling::Appointments::CancelService.new(
      appointment: appointment, actor: actor,
      appointment_access: mutation_access(appointment, appointment_access_token, patient_confirmed)
    ).perform
  end

  def create_appointment(resource_id:, starts_at:, ends_at: nil, duration_min: nil, service_id: nil, appointment_type: nil, client_comment: nil,
                         custom_attributes: nil, patient: nil, crm_deal_id: nil, crm_pipeline_id: nil)
    @persisted_creation = nil
    @already_booked_appointment = nil
    ensure_feature_enabled!('scheduling', 'Scheduling is not enabled for this account')
    resource_id = resolve_agent_resource_id(resource_id, service_id)
    starts_at, ends_at = normalize_appointment_times(resource_id: resource_id, starts_at: starts_at, ends_at: ends_at)
    validated_service = validate_booking_inputs!(starts_at: starts_at, ends_at: ends_at, duration_min: duration_min, service_id: service_id)
    validated_service, client_comment = bookable_service_and_comment(resource_id, validated_service, client_comment)
    service_id = validated_service&.id || (offered_service_id(resource_id) if service_id.blank?)

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
      crm_deal_id: crm_deal_id.presence || (active_current_deal_id if crm_pipeline_id.blank?),
      crm_pipeline_id: crm_pipeline_id,
      created_by_id: (actor.id if actor.is_a?(User)),
      custom_attributes: parsed_hash(custom_attributes, field_name: 'custom_attributes')
    }.compact

    if patient.present?
      create_params.merge!(Captain::Tools::Agent::PatientBookingContext.new(
        assistant: assistant, conversation: conversation, patient: patient
      ).perform)
    end

    persist_creation!(create_params)
  end

  def update_current_appointment(appointment_id: nil, resource_id: nil, service_id: SERVICE_OMITTED, starts_at: nil, ends_at: nil, duration_min: nil,
                                 appointment_type: nil, client_comment: nil, custom_attributes: nil,
                                 appointment_access_token: nil, patient_confirmed: false)
    @unchanged_appointment = nil
    ensure_feature_enabled!('scheduling', 'Scheduling is not enabled for this account')
    appointment = target_appointment(appointment_id, appointment_access_token: appointment_access_token, patient_confirmed: patient_confirmed)

    starts_at, ends_at = normalize_appointment_times(resource_id: resource_id || appointment.resource_id, starts_at: starts_at, ends_at: ends_at)
    explicit_service = !service_id.equal?(SERVICE_OMITTED)
    resource_changed = resource_id.present? && resource_id.to_i != appointment.resource_id
    validated_service = validate_booking_inputs!(starts_at: starts_at, ends_at: ends_at, duration_min: duration_min,
                                                 service_id: explicit_service ? service_id : nil, appointment: appointment)
    candidate_service = explicit_service ? validated_service : (appointment.service if resource_changed)
    validated_service, client_comment = bookable_service_and_comment(resource_id || appointment.resource_id, candidate_service,
                                                                     client_comment || appointment.client_comment)
    service_id = validated_service&.id

    params = {}
    params[:resource_id] = resource_id unless resource_id.nil?
    params[:service_id] = service_id if explicit_service || (resource_changed && candidate_service.present? && service_id.nil?)
    params[:starts_at] = starts_at unless starts_at.nil?
    params[:ends_at] = ends_at unless ends_at.nil?
    params[:duration_min] = duration_min unless duration_min.nil?
    params[:appointment_type] = appointment_type unless appointment_type.nil?
    params[:client_comment] = client_comment unless client_comment.nil?
    params[:custom_attributes] = parsed_hash(custom_attributes, field_name: 'custom_attributes') if custom_attributes.present?

    # A change that asks for what the appointment already has (the same time, the same specialist) is not sent again, to the
    # provider either: a second message or a second agent that repeats a move changes nothing.
    if appointment_unchanged?(appointment, params)
      @unchanged_appointment = appointment
      return appointment
    end

    if imported_appointment?(appointment)
      return mutate_imported_appointment(appointment, 'move_reception', params, appointment_access_token, patient_confirmed)
    end

    ::Scheduling::Appointments::UpsertService.new(
      account: account,
      params: params,
      appointment: appointment,
      actor: actor,
      appointment_access: mutation_access(appointment, appointment_access_token, patient_confirmed)
    ).perform
  end

  private

  # An active appointment whose every field in the change equals what it holds. A custom attribute cannot be compared, so it is a
  # change; a cancelled or finished appointment goes through the normal path, which says why it cannot be changed.
  def appointment_unchanged?(appointment, params)
    appointment.status.in?(%w[scheduled confirmed]) && params.present? &&
      params.all? { |field, value| unchanged_field?(appointment, field, value) }
  end

  def unchanged_field?(appointment, field, value)
    return integer_value(value) == appointment.public_send(field) if UNCHANGED_INTEGER_FIELDS.include?(field)
    return same_instant?(value, appointment.public_send(field)) if UNCHANGED_TIME_FIELDS.include?(field)

    UNCHANGED_TEXT_FIELDS.include?(field) && value.to_s == appointment.public_send(field).to_s
  end

  def integer_value(value)
    ::Scheduling::IntegerNumericNormalizer.normalize_value(value)
  end

  def same_instant?(value, time)
    time.present? && Time.zone.parse(value.to_s)&.to_i == time.to_i
  rescue ArgumentError
    false
  end

  def normalize_appointment_times(resource_id:, starts_at:, ends_at:)
    return [starts_at, ends_at] if starts_at.nil? && ends_at.nil?

    resource = account.scheduling_resources.find_by(id: required_positive_id(resource_id, field_name: 'resource_id'))
    raise Scheduling::Error.new(code: 'RESOURCE_UNAVAILABLE', message: 'Resource is not available', status: :not_found) unless resource

    input = Captain::Tools::Agent::AppointmentTimeInput
    zone = input.timezone(resource_timezone: resource.timezone, account_timezone: account.reporting_timezone)
    [[:starts_at, starts_at], [:ends_at, ends_at]].map do |field, value|
      input.parse(value, timezone: zone, field_name: field.to_s).iso8601 unless value.nil?
    end
  end

  def validate_booking_inputs!(starts_at:, ends_at:, duration_min:, service_id:, appointment: nil)
    start_time = starts_at.nil? && appointment ? appointment.starts_at : Scheduling::InputValidation.datetime(starts_at, field_name: 'starts_at')
    if !ends_at.nil?
      end_time = Scheduling::InputValidation.datetime(ends_at, field_name: 'ends_at')
      Scheduling::InputValidation.interval!(starts_at: start_time, ends_at: end_time)
    elsif !duration_min.nil?
      duration = Scheduling::IntegerNumericNormalizer.normalize_or_zero(duration_min, field_name: 'duration_min')
      Scheduling::InputValidation.interval!(starts_at: start_time, ends_at: start_time + duration.minutes)
    end
    ensure_future_start!(starts_at, start_time, appointment)
    # Keep an inactive catalog record long enough to preserve the patient's requested name in the comment.
    if service_id.present?
      id = Scheduling::IntegerNumericNormalizer.normalize(service_id, field_name: 'service_id')
      account.scheduling_services.find_by(id: id) || Scheduling::InputValidation.service!(account: account, value: service_id)
    end
  rescue Scheduling::Error => e
    # This boundary only parses arguments and reads the catalog. No local or
    # provider mutation has started, so a corrected call is safe.
    raise Scheduling::Error.new(code: e.code, message: e.message, status: e.status,
                                details: e.details.to_h.merge(mutation_executed: false))
  rescue ArgumentError => e
    raise Scheduling::Error.new(code: 'INVALID_DURATION', message: e.message, status: :unprocessable_entity,
                                details: { mutation_executed: false })
  end

  # A booking or a move by the AI in a patient conversation (the agent's own tools, the approval card of a reply suggestion, an
  # account tool in the patient scope: the actor is the assistant) never starts at a time that has passed: nothing is written, and
  # the answer names the clinic's current time so the agent searches free times from now. Staff and Copilot (the actor is a user)
  # may record a visit that already took place. starts_at is the local clock of the specialist with its offset (see
  # #normalize_appointment_times), so the times of the answer are the clinic's. A change without a new start, or with the start the
  # appointment already has, is not checked: it moves nothing.
  def ensure_future_start!(starts_at, start_time, appointment = nil)
    return unless actor.is_a?(Captain::Assistant)
    return if starts_at.nil? || start_time > Time.current || (appointment && same_instant?(starts_at, appointment.starts_at))

    local = Time.iso8601(starts_at.to_s)
    now = Time.current.getlocal(local.utc_offset)
    raise Scheduling::Error.new(
      code: START_IN_PAST_CODE, status: :unprocessable_content,
      message: "The start #{local.strftime(START_LABEL_FORMAT)} has passed (now is #{now.strftime(START_LABEL_FORMAT)})",
      details: { field: 'starts_at', reason: 'start_in_past', now: now.strftime(START_LABEL_FORMAT), next_tool: 'search_available_slots' }
    )
  rescue ArgumentError
    raise Scheduling::Error.new(code: START_IN_PAST_CODE, status: :unprocessable_content, message: 'The start has passed',
                                details: { field: 'starts_at', reason: 'start_in_past', next_tool: 'search_available_slots' })
  end

  def imported_appointment?(appointment)
    appointment.source == ::Scheduling::Appointments::MutationGuard::PROVIDER_SOURCE
  end

  def mutate_imported_appointment(appointment, operation, params, token, confirmed)
    ::Scheduling::Appointments::ImportedProviderMutationService.new(
      appointment: appointment, actor: actor, operation: operation, params: params,
      appointment_access: mutation_access(appointment, token, confirmed)
    ).perform
  end

  def active_current_deal_id
    deal = current_deal
    return if deal.blank?

    scope = ::Crm::Appointments::CandidateScope.resolve(account: account, contact: current_contact)
    deal.id if scope.exists?(id: deal.id)
  end

  def mutation_access(appointment, token, confirmed)
    return unless actor.is_a?(Captain::Assistant)

    { token: token.presence || Captain::Tools::Agent::AppointmentAccess.issue(
      assistant: assistant, conversation: conversation, appointment: appointment
    ), conversation_id: conversation.id, patient_confirmed: confirmed }
  end

  # Attach only the sole priceable service when its MedElement mapping is available. Staff choose their service themselves.
  def offered_service_id(resource_id)
    return unless actor.is_a?(Captain::Assistant)

    choice = Captain::Tools::Agent::BookingServiceChoice.new(
      account: account, resource_id: required_positive_id(resource_id, field_name: 'resource_id')
    )
    service = choice.perform
    return unless service

    resource = account.scheduling_resources.find(resource_id)
    service.id if Scheduling::Appointments::ServiceConfirmation.bookable?(service: service, resource: resource)
  end

  def bookable_service_and_comment(resource_id, service, comment)
    return [nil, comment] unless service

    resource = account.scheduling_resources.find(resource_id)
    return [service, comment] if Scheduling::Appointments::ServiceConfirmation.bookable?(service: service, resource: resource)

    [nil, comment.to_s.include?(service.name) ? comment : [comment.presence, "Услуга: #{service.name}"].compact.join("\n")]
  end

  # The active appointment of the same patient with the same specialist, the same service and the same start. A booking of the agent
  # that asks for it again is answered with this one: a second appointment would be a double booking. Another service at that
  # start is another booking: the slot is taken and the answer says so.
  def existing_booking(create_params)
    patient_id = create_params[:patient_contact_id] || create_params[:contact_id]
    return unless actor.is_a?(Captain::Assistant) && patient_id.present?

    starts_at = Time.zone.parse(create_params[:starts_at].to_s)
    account.scheduling_appointments.where(status: %w[scheduled confirmed], resource_id: create_params[:resource_id], starts_at: starts_at,
                                          service_id: create_params[:service_id])
           .where('COALESCE(patient_contact_id, contact_id) = ?', patient_id).order(:id).first
  end

  # Another part of the same request may have booked it between the check and the write: the slot is then taken by the very
  # appointment this call asks for, which is the answer.
  def perform_or_find_booking(upsert, create_params)
    upsert.perform
  rescue Scheduling::Error => e
    raise unless Captain::Tools::Agent::AppointmentResult::CONFLICT_CODES.include?(e.code.to_s)

    @already_booked_appointment = existing_booking(create_params) || raise
  end

  def persist_creation!(create_params)
    upsert = nil
    appointment = with_idempotent_creation('create_appointment', create_params.except(:patient_selection_token)) do
      @already_booked_appointment = existing_booking(create_params)
      next @already_booked_appointment if @already_booked_appointment

      upsert = ::Scheduling::Appointments::UpsertService.new(account: account, params: create_params, actor: actor)
      perform_or_find_booking(upsert, create_params)
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
      assistant: assistant, tool_id: 'create_appointment', params: create_params.except(:patient_selection_token),
      scope: idempotency_scope, record: persisted_creation
    )
  end

  def target_appointment(appointment_id, appointment_access_token: nil, patient_confirmed: false)
    raise ArgumentError, 'Current conversation is not available' if conversation.blank?

    if actor.is_a?(Captain::Assistant) && appointment_access_token.present?
      appointment = Captain::Tools::Agent::AppointmentAccess.resolve(
        token: appointment_access_token, assistant: assistant, conversation: conversation, appointment_id: appointment_id
      )
      raise ArgumentError, 'Record is not available' unless appointment

      require_patient_confirmation!(appointment, patient_confirmed)
      return scoped_appointment!(appointment)
    end

    appointments = account.scheduling_appointments.where(conversation_id: conversation.id)
    unless appointment_id.nil?
      appointment = explicit_target_appointment(explicit_appointments_scope(appointments), appointment_id)
      require_patient_confirmation!(appointment, patient_confirmed)
      return scoped_appointment!(appointment)
    end

    compatible_appointments = appointments.limit(2).to_a
    raise ArgumentError, 'Current appointment is not available' if compatible_appointments.empty?
    raise ArgumentError, 'appointment_id is required when the conversation has multiple appointments' if compatible_appointments.many?

    appointment = compatible_appointments.first
    require_patient_confirmation!(appointment, patient_confirmed)
    scoped_appointment!(appointment)
  end

  def scoped_appointment!(appointment)
    appointment
  end

  def resolve_agent_resource_id(resource_id, service_id)
    return resource_id unless actor.is_a?(Captain::Assistant) && service_id.present?
    return resource_id if account.scheduling_resources.exists?(id: resource_id)

    linked = Scheduling::ServicePrice.active.where(account_id: account.id, service_id: service_id).distinct.pluck(:resource_id)
    linked.one? ? linked.first : resource_id
  rescue StandardError
    resource_id
  end

  def require_patient_confirmation!(appointment, confirmed)
    verify_appointment_disambiguation!(appointment) if actor.is_a?(Captain::Assistant)
    return unless actor.is_a?(Captain::Assistant) && Captain::Tools::Agent::AppointmentAccess.other_patient?(appointment, conversation)
    return if confirmed == true

    raise ArgumentError, 'Confirm the specific patient, doctor, appointment time and requested change before applying it'
  end

  def verify_appointment_disambiguation!(appointment, action_name: :cancel_or_reschedule)
    disambiguation = ::Captain::Appointments::TargetDisambiguationService.new(
      account: account,
      conversation: conversation,
      target_appointment: appointment,
      action_type: action_name
    ).perform
    return if disambiguation.confirmed?

    raise ArgumentError, disambiguation.clarification_message
  end

  def explicit_appointments_scope(conversation_appointments)
    return conversation_appointments unless actor.is_a?(Captain::Assistant) && current_contact.present?

    account.scheduling_appointments.where(contact_id: current_contact.id).or(conversation_appointments)
  end

  def explicit_target_appointment(appointments, appointment_id)
    appointment_id = required_positive_id(appointment_id, field_name: 'appointment_id')
    appointment = appointments.find_by(id: appointment_id)
    if appointment.blank?
      message = actor.is_a?(Captain::Assistant) ? 'Record is not available' : 'Appointment is not available for the current conversation'
      raise ArgumentError, message
    end

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
