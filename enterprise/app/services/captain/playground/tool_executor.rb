# Synthetic records always stop here, including when real-data access is enabled.
class Captain::Playground::ToolExecutor
  include Captain::Playground::SchedulingTools
  include Captain::Playground::SchedulingCatalogTools
  include Captain::Playground::AvailabilityTools
  include Captain::Playground::SlotCalendar
  include Captain::Playground::AppointmentAccessTools
  include Captain::Playground::AppointmentQueryTools
  include Captain::Playground::CrmTools
  include Captain::Playground::PatientTools
  include Captain::Playground::ConversationTools
  include Captain::Playground::ConfirmationTools
  include Captain::Playground::TaskTools
  include Captain::Playground::DealStageTools
  include Captain::Playground::CustomFieldTools
  include Captain::Playground::KnowledgeTools
  include Captain::Playground::ContactCompanyTools
  include Captain::Playground::RecordSnapshots
  include Captain::Playground::TouchTools

  APPOINTMENT_TOOLS = %w[create_appointment update_appointment cancel_appointment get_appointment search_appointments].freeze
  HANDLERS = {
    'search_documentation' => :search_documentation, 'list_captain_documents' => :captain_documents, 'faq_lookup' => :faq_lookup,
    'get_article' => :article_details, 'search_articles' => :search_articles, 'search_canned_responses' => :search_canned_responses,
    'get_contact' => :contact_details, 'search_contacts' => :search_contacts, 'update_contact' => :update_contact,
    'get_company' => :company_details, 'search_companies' => :search_companies,
    'create_company' => :create_company, 'update_company' => :update_company,
    'search_scheduling_resources' => :scheduling_resources, 'list_scheduling_resources' => :scheduling_resources,
    'search_scheduling_services' => :scheduling_services, 'get_scheduling_resource' => :resource_details,
    'get_scheduling_resource_schedule' => :resource_schedule, 'get_scheduling_resource_availability' => :resource_availability,
    'search_available_slots' => :available_slots, 'create_appointment' => :create_appointment,
    'update_appointment' => :update_appointment, 'cancel_appointment' => :cancel_appointment,
    'get_appointment' => :appointment_details, 'search_appointments' => :search_appointments, 'list_my_appointments' => :list_my_appointments,
    'get_deal' => :deal_details, 'search_deals' => :search_deals, 'list_deal_pipelines' => :deal_pipelines,
    'list_deal_stages' => :deal_stages, 'create_deal' => :create_deal, 'update_deal' => :update_deal,
    'transition_deal_stage' => :update_deal, 'create_task' => :create_task, 'search_tasks' => :search_tasks,
    'get_task' => :task_details, 'update_task' => :update_task, 'change_task_status' => :change_task_status, 'complete_task' => :complete_task,
    'add_contact_note' => :add_note, 'add_private_note' => :add_note, 'add_label_to_conversation' => :change_label,
    'remove_label_from_conversation' => :change_label, 'update_priority' => :update_priority,
    'resolve_conversation' => :resolve_conversation, 'assign_conversation' => :assign_conversation,
    'get_conversation' => :conversation_details, 'search_conversations' => :search_conversations,
    'send_message_to_conversation' => :simulate_message, 'request_confirmation' => :request_confirmation,
    'get_confirmation_request' => :confirmation_details, 'resolve_confirmation' => :resolve_confirmation,
    'send_notification' => :send_notification, 'retry_failed_message' => :retry_failed_message, 'edit_message' => :edit_message,
    'cancel_response' => :cancel_response, 'merge_contacts' => :merge_contacts,
    'list_channel_templates' => :channel_templates, 'create_touch' => :create_touch, 'cancel_touch' => :cancel_touch,
    'delete_touch' => :delete_touch, 'cancel_touches' => :cancel_touches,
    'get_deal_timeline' => :record_timeline_details, 'get_task_timeline' => :record_timeline_details,
    'handoff' => :simulate_handoff
  }.freeze

  def initialize(session)
    @session = session
    @scenario = session.scenario
    @data = @scenario.data
  end

  def execute(tool_id, arguments, context:)
    @original_data = nil
    @session.assert_context!(context.state)
    @context = Struct.new(:state, :context).new(@session.namespace.decode(context.state), context.context)
    @tool_id = tool_id.to_s
    @args = @session.namespace.decode(arguments.to_h).deep_stringify_keys.compact
    authorize_tool!
    @original_data = @data.deep_dup
    result = dispatch
    @scenario.validate
    context.state.merge!(@session.state)
    context.state[:prompt_context] = @session.assistant.prompt_context_state(context.state)
    encoded = @session.namespace.encode(result)
    # Domain payloads may contain message/success keys that are not ToolResult
    # envelope fields. Preserve the entire payload and Rails' native JSON time
    # serialization through the actual wrapper; normalized failures stay intact.
    domain_payload = encoded.is_a?(Hash) && (encoded.keys.map(&:to_sym) - Captain::ToolResult::NORMALIZED_KEYS).any?
    return JSON.generate(encoded.as_json) if domain_payload

    encoded
  rescue ArgumentError, KeyError, TypeError, Crm::Error, Scheduling::Error, ActiveRecord::RecordNotFound => e
    @data.replace(@original_data) if @original_data
    if APPOINTMENT_TOOLS.include?(tool_id.to_s)
      return JSON.generate(success: false, reason: e.message == 'Record is not available' ? 'not_found' : 'validation_error')
    end

    Captain::ToolResult.failure(error: e.message, retryable: false)
  end

  private

  def authorize_tool!
    definition = Captain::ToolRegistry.definition_for(@tool_id)
    raise ArgumentError, 'Tool is unavailable in this Playground session' unless definition
    return if Captain::ToolPolicy.execution_allowed?(definition.to_h, assistant: @session.assistant, scope_name: Captain::ToolAccess::SCOPE_AGENT)

    raise ArgumentError, 'Tool is not available for this agent profile'
  end

  def dispatch
    handler = HANDLERS[@tool_id]
    return send(handler) if handler
    return custom_field_catalog if @tool_id.match?(/\Alist_(?:deal|task|appointment|contact)_custom_fields\z/)

    Captain::Playground::ToolSupport.failure(@tool_id)
  end

  def caller
    @scenario.contact
  end

  def record!(collection, id)
    @data.fetch(collection).find { |record| record['id'].to_s == id.to_s } || raise(ArgumentError, 'Record is not available')
  end

  def require_caller_filter!
    raise ArgumentError, 'Record is not available' if @args['contact_id'].present? && @args['contact_id'].to_s != caller['id'].to_s
  end

  def resource_details
    { resource: resource!(@args.fetch('resource_id')).deep_dup, simulated: true }
  end

end
