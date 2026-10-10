require 'json_schemer'

class Captain::Playground::RealToolExecutor
  READ_TOOLS = %w[
    get_contact search_contacts get_company search_companies get_deal search_deals list_deal_pipelines list_deal_stages get_deal_timeline get_task search_tasks get_task_timeline
    get_appointment search_appointments list_my_appointments search_scheduling_resources list_scheduling_resources
    get_scheduling_resource search_scheduling_services search_available_slots
    get_scheduling_resource_schedule get_scheduling_resource_availability
    list_deal_custom_fields list_task_custom_fields list_appointment_custom_fields
    get_conversation search_conversations get_confirmation_request list_channel_templates
    search_documentation list_captain_documents faq_lookup get_article search_articles search_canned_responses get_workspace_profile
  ].freeze
  DELIVERY_TOOLS = %w[send_notification send_message_to_conversation retry_failed_message edit_message request_confirmation create_touch].freeze
  CONTEXT_TOOLS = %w[create_deal create_task update_deal update_task update_appointment cancel_appointment create_company update_company update_contact add_contact_note add_private_note
                     add_label_to_conversation remove_label_from_conversation update_priority resolve_conversation
                     handoff transition_deal_stage change_task_status complete_task assign_conversation send_notification
                     send_message_to_conversation retry_failed_message edit_message cancel_response request_confirmation get_confirmation_request
                     list_channel_templates create_touch cancel_touches].freeze
  REFERENCES = {
    'contact_id' => :contacts, 'deal_id' => :crm_deals, 'crm_deal_id' => :crm_deals, 'task_id' => :crm_tasks,
    'appointment_id' => :scheduling_appointments, 'resource_id' => :scheduling_resources, 'service_id' => :scheduling_services,
    'pipeline_id' => :crm_pipelines, 'crm_pipeline_id' => :crm_pipelines, 'stage_id' => :crm_stages, 'company_id' => :companies,
    'base_contact_id' => :contacts, 'mergee_contact_id' => :contacts, 'touch_id' => :reminders,
    'confirmation_request_id' => :confirmation_requests, 'message_id' => :messages
  }.freeze

  def initialize(session)
    @session = session
  end

  def synthetic?(tool_id, arguments)
    return true if @session.namespace.synthetic?(arguments)
    return true if CONTEXT_TOOLS.include?(tool_id) && !explicit_target?(arguments)
    return true if tool_id == 'create_appointment' && arguments.to_h.with_indifferent_access[:patient].blank?

    !@session.read_enabled? && !explicit_target?(arguments)
  end

  def read?(tool_id) = READ_TOOLS.include?(tool_id)

  def prepare(tool_id, arguments)
    raise ArgumentError, 'Reading real data is disabled' unless @session.read_enabled?
    raise ArgumentError, Outbound::PlaygroundDeliveryPolicy::BLOCKED_MESSAGE if DELIVERY_TOOLS.include?(tool_id)
    raise ArgumentError, 'A synthetic reference cannot be used for a real action' if @session.namespace.synthetic?(arguments)

    definition = Captain::ToolRegistry.definition_for(tool_id)
    raise ArgumentError, 'No production service is registered for this tool' unless definition&.assistant_tool_class
    @session.assistant.reload
    unless Captain::Playground::ToolSelection.include?(@session.assistant, tool_id) &&
           Captain::ToolPolicy.execution_allowed?(definition.to_h, assistant: @session.assistant, scope_name: Captain::ToolAccess::SCOPE_AGENT)
      raise Pundit::NotAuthorizedError, 'Tool is not selected in this agent profile'
    end
    unless Captain::ToolPolicy.execution_allowed?(definition.to_h, assistant: @session.assistant,
                                                  scope_name: Captain::ToolAccess::SCOPE_ASSISTANT, user: @session.user)
      raise Pundit::NotAuthorizedError, 'Tool permission is not available for the current operator'
    end
    arguments = arguments.to_h.deep_symbolize_keys.compact
    validate_arguments!(definition, arguments)
    records = resolve_references(arguments)
    records['patient'] = existing_real_patient!(arguments[:patient]) if tool_id == 'create_appointment'
    conversation = resolve_conversation(arguments, records)
    authorize_records!(records, mutation: !read?(tool_id))
    arguments = exact_appointment_arguments(tool_id, arguments, records)
    delegate = definition.assistant_tool_class.new(@session.assistant, user: @session.user, conversation: conversation)
    # Explicit target operations may have an old active? implementation requiring
    # a conversation. Record policies and the operation itself are authoritative.
    if read?(tool_id) && !delegate.active?
      raise Pundit::NotAuthorizedError, 'Tool permission is not available for the current operator'
    end
    snapshot = records.transform_values do |record|
      target = { id: record.id, type: record.class.name, updated_at: record.updated_at&.utc&.iso8601(6),
                 name: record.try(:name) || record.try(:title), status: record.try(:status) }.compact
      target[:values] = record.attributes.slice('name', 'title', 'email', 'phone_number', 'identifier', 'description', 'priority', 'status',
                                                'due_at', 'assignee_id', 'team_id', 'crm_pipeline_id', 'crm_stage_id', 'custom_attributes')
      if record.is_a?(Contact)
        policy = Integrations::Medelement::AppointmentPatientIdentity
        target[:clinical_identity] = policy.contact_names(record).merge('iin' => policy.contact_iin(record),
          'birth_date' => record.custom_attributes.to_h['medelement_birth_date'].presence || record.custom_attributes.to_h['birth_date'])
      elsif record.is_a?(Scheduling::Appointment)
        policy = Integrations::Medelement::AppointmentPatientIdentity
        target[:appointment] = {
          patient_contact_id: record.patient_contact_id || record.contact_id,
          patient_identity: policy.current_snapshot(record), resource_id: record.resource_id, service_id: record.service_id,
          starts_at: record.starts_at&.iso8601, ends_at: record.ends_at&.iso8601, duration_min: record.duration_min,
          cabinet_code: record.custom_attributes.to_h['medelement_cabinet_code']
        }
      end
      target
    end
    { delegate: delegate, arguments: arguments, target: snapshot, records: records, conversation: conversation }
  end

  def execute(tool_id, arguments, prepared: nil)
    prepared ||= prepare(tool_id, arguments)
    if read?(tool_id)
      raise ArgumentError, 'Reading real data is disabled' unless @session.read_enabled?
      return ActiveRecord::Base.connected_to(role: :writing, prevent_writes: true) { execute_prepared(tool_id, prepared) }
    end

    ActiveRecord::Base.transaction do
      prepared.fetch(:records).values.uniq.sort_by { |record| [record.class.name, record.id] }.each(&:lock!)
      fresh = prepare(tool_id, prepared.fetch(:arguments))
      unless fresh[:target].deep_stringify_keys == prepared[:target].deep_stringify_keys
        raise ArgumentError, 'The target or payload changed; review a new preview'
      end
      unless Outbound::PlaygroundMutationPolicy.authorized_action?(Current.playground_run_policy)
        raise ArgumentError, 'The real-action confirmation was revoked'
      end
      execute_prepared(tool_id, fresh)
    end
  end

  private

  def execute_prepared(tool_id, prepared)
    result = if tool_id == 'create_appointment'
               execute_create_appointment(prepared)
             elsif %w[update_appointment cancel_appointment].include?(tool_id)
               execute_appointment_mutation(tool_id, prepared)
             else
               execute_delegate(prepared)
             end
    Captain::Tools::ProviderReceiptProjection.for_agent(result)
  end

  def execute_delegate(prepared)
    delegate = prepared.fetch(:delegate)
    method = delegate.method(:execute)
    method = method.super_method if method.owner == Captain::Tools::Instrumentation && method.super_method
    method.call(**prepared.fetch(:arguments))
  end

  def validate_arguments!(definition, arguments)
    klass = definition.agent_tool_class
    tool = if klass == Captain::Tools::Agent::AccountToolAdapter
             klass.new(@session.assistant, tool_id: definition.id)
           else
             klass.new(@session.assistant)
           end
    errors = JSONSchemer.schema(tool.params_schema.deep_stringify_keys).validate(arguments.deep_stringify_keys).to_a
    raise ArgumentError, 'Arguments do not match the production tool schema' if errors.any?
  end

  def exact_appointment_arguments(tool_id, arguments, records)
    return arguments unless %w[create_appointment update_appointment].include?(tool_id) && arguments[:ends_at].blank?
    existing = records['appointment_id']
    return arguments unless arguments[:starts_at].present? || arguments[:duration_min].present? || arguments[:service_id].present?

    starts_at = arguments[:starts_at].presence || existing&.starts_at&.iso8601
    raise ArgumentError, 'Confirm the appointment start time' unless starts_at

    duration = arguments[:duration_min].presence || records['service_id']&.duration_min || existing&.duration_min ||
               records['resource_id']&.slot_duration_min
    raise ArgumentError, 'Confirm the appointment duration or exact end time' unless duration.to_i.positive?

    arguments.merge(starts_at: starts_at, ends_at: (Time.iso8601(starts_at) + duration.to_i.minutes).iso8601)
  end

  def explicit_target?(arguments)
    arguments.to_h.any? do |key, value|
      (REFERENCES.key?(key.to_s) || %w[conversation_id originating_conversation_id].include?(key.to_s)) && value.to_i.positive?
    end
  end

  def resolve_references(arguments)
    result = REFERENCES.each_with_object({}) do |(key, association), records|
      value = arguments[key.to_sym]
      next if value.blank?
      raise ArgumentError, 'Real references must be positive integers' unless value.to_s.match?(/\A[1-9]\d*\z/)

      records[key] = @session.account.public_send(association).find(value)
    end
    if arguments[:resource_ids].present?
      Array(arguments[:resource_ids]).each_with_index do |value, index|
        raise ArgumentError, 'Real references must be positive integers' unless value.to_s.match?(/\A[1-9]\d*\z/)

        result["resource_ids.#{index}"] = @session.account.scheduling_resources.find(value)
      end
    end
    result.values.grep(ConfirmationRequest).each do |record|
      result['confirmation_contact'] = @session.account.contacts.find(record.contact_id) if record.contact_id
    end
    result
  end

  def resolve_conversation(arguments, records)
    reference = arguments[:conversation_id].presence || arguments[:originating_conversation_id].presence
    relation = Conversations::PermissionFilterService.new(@session.account.conversations, @session.user, @session.account).perform
    if reference
      conversation = relation.find_by!(display_id: reference)
      records['conversation'] = conversation
      return conversation
    end
    record = records['deal_id'] || records['appointment_id'] || records['task_id'] || records['touch_id'] ||
             records['confirmation_request_id'] || records['message_id']
    conversation_id = record.try(:originating_conversation_id) || record.try(:conversation_id)
    conversation = relation.find_by!(id: conversation_id) if conversation_id
    records['conversation'] = conversation if conversation
    conversation
  end

  def authorize_records!(records, mutation:)
    context = { user: @session.user, account: @session.account,
                account_user: @session.account.account_users.find_by!(user_id: @session.user.id) }
    records.each_value do |record|
      policy = case record
               when Contact then ContactPolicy.new(context, record)
               when Crm::Deal then Crm::DealPolicy.new(context, record)
               when Crm::Task then Crm::TaskPolicy.new(context, record)
               when Conversation then ConversationPolicy.new(context, record)
               when Reminder then ReminderPolicy.new(context, record)
               end
      next unless policy
      next if policy.public_send(mutation ? :update? : :show?)

      raise Pundit::NotAuthorizedError, 'Record is not available for the current operator'
    end
  end

  def execute_create_appointment(prepared)
    arguments = prepared.fetch(:arguments)
    contact = existing_real_patient!(arguments[:patient])
    unless prepared.dig(:target, 'patient', :id) == contact.id
      raise ArgumentError, 'The confirmed patient card changed'
    end
    params = arguments.except(:patient).merge(contact_id: contact.id, patient_contact_id: contact.id)
    appointment = Scheduling::Appointments::UpsertService.new(account: @session.account, params: params, actor: @session.user).perform
    JSON.generate(Scheduling::ToolPayloadBuilder.appointment_payload(action: 'create_appointment', appointment: appointment))
  end

  def execute_appointment_mutation(tool_id, prepared)
    arguments = prepared.fetch(:arguments)
    appointment = @session.account.scheduling_appointments.find(arguments.fetch(:appointment_id))
    params = arguments.except(:appointment_id, :appointment_access_token, :patient_confirmed)
    if appointment.source == Scheduling::Appointments::MutationGuard::PROVIDER_SOURCE
      appointment = Scheduling::Appointments::ImportedProviderMutationService.new(
        appointment: appointment, actor: @session.user,
        operation: tool_id == 'cancel_appointment' ? 'remove_reception' : 'move_reception', appointment_access: {}, params: params
      ).perform
    elsif tool_id == 'cancel_appointment'
      appointment = Scheduling::Appointments::CancelService.new(appointment: appointment, actor: @session.user).perform
    else
      appointment = Scheduling::Appointments::UpsertService.new(account: @session.account, appointment: appointment,
                                                               params: params, actor: @session.user).perform
    end
    JSON.generate(Scheduling::ToolPayloadBuilder.appointment_payload(action: tool_id, appointment: appointment))
  end

  def existing_real_patient!(details)
    patient = details.to_h.with_indifferent_access
    raise ArgumentError, 'Select an existing real patient by IIN before creating a real appointment' if patient[:iin].blank?
    patient[:iin] = Scheduling::IinValidator.normalize(patient[:iin])
    Scheduling::IinValidator.validate!(patient[:iin])
    if @session.scenario.data['contacts'].any? { |item| Scheduling::IinValidator.normalize(item['identifier']) == patient[:iin] }
      raise ArgumentError, 'Synthetic patients cannot be promoted into real data'
    end
    contact = Integrations::Medelement::PatientContactBinding.recorded_contact_by_iin(account: @session.account, iin: patient[:iin])
    raise ArgumentError, 'An exact existing real patient is required' unless contact
    policy = Integrations::Medelement::AppointmentPatientIdentity
    identity = policy::NAME_KEYS.index_with { |key| patient[key] }.symbolize_keys
    identity[:middle_name] = policy.contact_names(contact)['middle_name'] unless patient.key?(:middle_name)
    raise ArgumentError, 'Real patient name does not match the selected IIN' unless policy.names_match?(identity, contact)
    birth_date = contact.custom_attributes.to_h['medelement_birth_date'].presence || contact.custom_attributes.to_h['birth_date']
    if patient[:birth_date].present? && birth_date.present? && Date.iso8601(patient[:birth_date].to_s) != Date.iso8601(birth_date.to_s)
      raise ArgumentError, 'Real patient birth date does not match the selected card'
    end

    authorize_records!({ patient: contact }, mutation: true)
    contact
  end
end
