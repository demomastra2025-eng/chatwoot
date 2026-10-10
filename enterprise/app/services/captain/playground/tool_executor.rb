# Every Trial tool stops here. Unknown/custom/MCP/network tools fail closed; they never fall through to a live delegate.
class Captain::Playground::ToolExecutor
  include Captain::Playground::SchedulingTools
  include Captain::Playground::CrmTools

  APPOINTMENT_TOOLS = %w[create_appointment update_appointment cancel_appointment get_appointment search_appointments].freeze

  def initialize(session)
    @session = session
    @scenario = session.scenario
    @data = @scenario.data
  end

  def execute(tool_id, arguments, context:)
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
    case @tool_id
    when 'get_contact' then get_contact
    when 'update_contact' then update_contact
    when 'search_scheduling_resources', 'list_scheduling_resources' then scheduling_resources
    when 'search_scheduling_services' then scheduling_services
    when 'get_scheduling_resource' then resource!(@args.fetch('resource_id')).deep_dup
    when 'search_available_slots' then available_slots
    when 'create_appointment' then create_appointment
    when 'update_appointment' then update_appointment
    when 'cancel_appointment' then cancel_appointment
    when 'get_appointment' then get_appointment
    when 'search_appointments' then search_appointments
    when 'list_my_appointments' then list_my_appointments
    when 'get_appointment_provider_status' then { success: false, reason: 'staff_will_help' }
    when 'get_deal' then deal_payload(deal!(@args.fetch('deal_id')))
    when 'search_deals' then search_deals
    when 'list_deal_pipelines' then { pipelines: @data['pipelines'].map { |pipeline| pipeline.merge('stages' => @data['stages'].select { |stage| stage['pipeline_id'] == pipeline['id'] }) } }
    when 'list_deal_stages' then deal_stages
    when 'create_deal' then create_deal
    when 'update_deal', 'transition_deal_stage' then update_deal
    when 'create_task' then create_task
    when 'search_tasks' then { tasks: @data['tasks'].select { |task| task['contact_id'] == caller['id'] } }
    when 'get_task' then record!('tasks', @args.fetch('task_id'))
    when 'update_task', 'change_task_status' then update_task
    when 'add_contact_note', 'add_private_note' then add_note
    when 'add_label_to_conversation', 'remove_label_from_conversation' then change_label
    when 'update_priority' then update_priority
    when 'resolve_conversation' then resolve_conversation
    when 'assign_conversation' then { success: false, error: 'No staff assignment exists in this Trial scenario' }
    when 'get_conversation' then @data['conversation'].deep_dup
    when 'search_conversations' then { conversations: [@data['conversation'].deep_dup] }
    when 'send_message_to_conversation' then simulate_message
    when 'request_confirmation' then request_confirmation
    when 'get_confirmation_request' then record!('confirmations', @args.fetch('confirmation_request_id'))
    when 'resolve_confirmation' then resolve_confirmation
    when 'handoff' then simulate_handoff
    when /\Alist_(?:deal|task|appointment|contact)_custom_fields\z/ then { fields: [] }
    else
      Captain::ToolResult.failure(error: 'This tool is not supported by the Trial scenario; no real service was called',
                                  data: { code: 'trial_tool_unavailable', simulated: true }, retryable: false)
    end
  end

  def caller
    @scenario.contact
  end

  def record!(collection, id)
    @data.fetch(collection).find { |record| record['id'].to_s == id.to_s } || raise(ArgumentError, 'Record is not available')
  end

  def get_contact
    raise ArgumentError, 'Record is not available' unless @args.fetch('contact_id').to_s == caller['id'].to_s

    caller.deep_dup
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

  def add_note
    text = @args['note'].presence || @args['content'].presence || raise(ArgumentError, 'Note content is required')
    note = { 'id' => @scenario.next_id!, 'contact_id' => caller['id'], 'content' => text, 'private' => @tool_id == 'add_private_note' }
    @data['notes'] << note
    { action: @tool_id, note: note, simulated: true }
  end

  def change_label
    name = @args['label_name'].presence || raise(ArgumentError, 'Label name is required')
    labels = @data['conversation']['label_list']
    @tool_id == 'add_label_to_conversation' ? labels.push(name).uniq! : labels.delete(name)
    { action: @tool_id, conversation_id: @data['conversation']['display_id'], labels: labels.deep_dup, simulated: true }
  end

  def update_priority
    priority = @args.fetch('priority')
    raise ArgumentError, 'Invalid priority' unless %w[low medium high urgent none].include?(priority)

    @data['conversation']['priority'] = priority == 'none' ? nil : priority
    { action: @tool_id, priority: @data['conversation']['priority'], simulated: true }
  end

  def resolve_conversation
    @data['conversation']['status'] = 'resolved'
    { action: @tool_id, conversation_id: @data['conversation']['display_id'], status: 'resolved', simulated: true }
  end

  def simulate_message
    id = @args['conversation_id']
    unless id.blank? || [@data['conversation']['id'], @data['conversation']['display_id']].map(&:to_s).include?(id.to_s)
      raise ArgumentError, 'Record is not available'
    end
    content = @args['content'].presence || raise(ArgumentError, 'Message content is required')
    message = { 'id' => @scenario.next_id!, 'content' => content, 'status' => 'simulated', 'conversation_id' => @data['conversation']['id'] }
    @data['messages'] << message
    { action: @tool_id, message: message, simulated: true, delivered: false }
  end

  def request_confirmation
    confirmation = { 'id' => @scenario.next_id!, 'status' => 'pending', 'subject_kind' => @args['subject_kind'], 'contact_id' => caller['id'] }
    @data['confirmations'] << confirmation
    { confirmation_request: confirmation, simulated: true }
  end

  def resolve_confirmation
    record = record!('confirmations', @args.fetch('confirmation_request_id'))
    raise ArgumentError, 'Confirmation has already been resolved' unless record['status'] == 'pending'

    record['status'] = @args['status'].presence || @args['decision'].presence || raise(ArgumentError, 'Confirmation status is required')
    { confirmation_request: record.deep_dup, simulated: true }
  end

  def simulate_handoff
    @data['conversation']['status'] = 'open'
    { action: 'handoff', reason: @args['reason'], simulated: true, external_delivery: false }
  end
end
