# Every Trial tool stops here. Unknown/custom/MCP/network tools fail closed; they never fall through to a live delegate.
class Captain::Playground::ToolExecutor
  include Captain::Playground::SchedulingTools
  include Captain::Playground::CrmTools
  include Captain::Playground::PatientTools
  include Captain::Playground::ConversationTools
  include Captain::Playground::ConfirmationTools
  include Captain::Playground::TaskTools
  include Captain::Playground::DealStageTools

  APPOINTMENT_TOOLS = %w[create_appointment update_appointment cancel_appointment get_appointment search_appointments].freeze
  HANDLERS = {
    'get_contact' => :get_contact, 'update_contact' => :update_contact,
    'search_scheduling_resources' => :scheduling_resources, 'list_scheduling_resources' => :scheduling_resources,
    'search_scheduling_services' => :scheduling_services, 'get_scheduling_resource' => :get_resource,
    'search_available_slots' => :available_slots, 'create_appointment' => :create_appointment,
    'update_appointment' => :update_appointment, 'cancel_appointment' => :cancel_appointment,
    'get_appointment' => :get_appointment, 'search_appointments' => :search_appointments, 'list_my_appointments' => :list_my_appointments,
    'get_appointment_provider_status' => :unsupported_provider_status,
    'get_deal' => :get_deal, 'search_deals' => :search_deals, 'list_deal_pipelines' => :deal_pipelines,
    'list_deal_stages' => :deal_stages, 'create_deal' => :create_deal, 'update_deal' => :update_deal,
    'transition_deal_stage' => :update_deal, 'create_task' => :create_task, 'search_tasks' => :search_tasks,
    'get_task' => :get_task, 'update_task' => :update_task, 'change_task_status' => :change_task_status, 'complete_task' => :complete_task,
    'add_contact_note' => :add_note, 'add_private_note' => :add_note, 'add_label_to_conversation' => :change_label,
    'remove_label_from_conversation' => :change_label, 'update_priority' => :update_priority,
    'resolve_conversation' => :resolve_conversation, 'assign_conversation' => :unsupported_assignment,
    'get_conversation' => :get_conversation, 'search_conversations' => :search_conversations,
    'send_message_to_conversation' => :simulate_message, 'request_confirmation' => :request_confirmation,
    'get_confirmation_request' => :get_confirmation_request, 'resolve_confirmation' => :resolve_confirmation,
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
    @context = context
    @tool_id = tool_id.to_s
    @args = arguments.to_h.deep_stringify_keys.compact
    authorize_tool!
    @original_data = @data.deep_dup
    result = dispatch
    @scenario.validate
    context.state.merge!(@session.state)
    context.state[:prompt_context] = @session.assistant.prompt_context_state(context.state)
    result
  rescue ArgumentError, KeyError, Date::Error, TypeError => e
    @data.replace(@original_data) if @original_data
    if APPOINTMENT_TOOLS.include?(tool_id.to_s)
      return { success: false, reason: e.message == 'Record is not available' ? 'not_found' : 'validation_error' }
    end

    Captain::ToolResult.failure(error: e.message, retryable: false)
  end

  private

  def authorize_tool!
    definition = Captain::ToolRegistry.definition_for(@tool_id)
    raise ArgumentError, 'Tool is unavailable in this Trial session' unless definition
    return if Captain::ToolPolicy.execution_allowed?(definition.to_h, assistant: @session.assistant, scope_name: Captain::ToolAccess::SCOPE_AGENT)

    raise ArgumentError, 'Tool is not available for this agent profile'
  end

  def dispatch
    handler = HANDLERS[@tool_id]
    return send(handler) if handler
    return { fields: [] } if @tool_id.match?(/\Alist_(?:deal|task|appointment|contact)_custom_fields\z/)

    Captain::ToolResult.failure(error: 'This tool is not supported by the Trial scenario; no real service was called',
                                data: { code: 'trial_tool_unavailable', simulated: true }, retryable: false)
  end

  def caller
    @scenario.contact
  end

  def record!(collection, id)
    @data.fetch(collection).find { |record| record['id'].to_s == id.to_s } || raise(ArgumentError, 'Record is not available')
  end

  def get_contact
    raise ArgumentError, 'Record is not available' unless @args.fetch('contact_id').to_s == caller['id'].to_s

    { contact: caller.deep_dup }
  end

  def update_contact
    fields = @args.slice(*Captain::Playground::Scenario::CONTACT_FIELDS)
    raise ArgumentError, 'Contact phone must use E.164 format' if fields['phone_number'].present? && !fields['phone_number'].match?(/\A\+[1-9]\d{7,14}\z/)
    raise ArgumentError, 'Contact name is required' if fields.key?('name') && fields['name'].blank?
    if fields['email'].present? && !fields['email'].match?(Devise.email_regexp)
      raise ArgumentError, 'Contact email is invalid'
    end
    caller.merge!(fields.except('custom_attributes', 'additional_attributes'))
    caller['custom_attributes'] = caller['custom_attributes'].to_h.merge(json_object(fields['custom_attributes'])) if fields.key?('custom_attributes')
    { action: 'update_contact', contact: caller.deep_dup, simulated: true }
  end

  def json_object(value)
    value = JSON.parse(value) if value.is_a?(String)
    raise ArgumentError, 'Custom attributes must be an object' unless value.nil? || value.is_a?(Hash)
    raise ArgumentError, 'Unknown custom field; use the custom field catalogue first' if value.to_h.keys.any? { |key| !caller['custom_attributes'].to_h.key?(key) }

    value.to_h
  rescue JSON::ParserError
    raise ArgumentError, 'Custom attributes must be valid JSON'
  end

  def require_caller_filter!
    raise ArgumentError, 'Record is not available' if @args['contact_id'].present? && @args['contact_id'].to_s != caller['id'].to_s
  end

  def get_resource
    { resource: resource!(@args.fetch('resource_id')).deep_dup, simulated: true }
  end

  def unsupported_provider_status
    accessible_appointment!
    { success: false, reason: 'staff_will_help', simulated: true }
  end
end
