class Captain::Tools::BasePublicTool < Captain::Runtime::Tool
  include Captain::ToolResultOutput

  def initialize(assistant)
    @assistant = assistant
    super()
  end

  def name
    @name ||= Captain::ToolRegistry.definition_for_class(self.class, scope_name: tool_scope_name)&.id || super
  end

  def active?
    true
  end

  def execute(tool_context, **params)
    result = super
    audit_tool_execution(arguments: params, result: result, runtime_context: runtime_context(tool_context))
    result
  rescue StandardError => e
    audit_tool_execution(arguments: params, error: e, runtime_context: runtime_context(tool_context))
    raise
  end

  def permissions
    # Override in subclasses to specify required permissions
    # Returns empty array for public tools (no permissions required)
    []
  end

  private

  attr_reader :assistant

  def tool_scope_name
    Captain::ToolAccess::SCOPE_AGENT
  end

  def tool_definition
    definition = registry_definition ? registry_definition.to_h : {}
    definition[:id] ||= name
    definition[:title] ||= name.to_s.humanize
    definition[:required_permissions] = permissions if definition[:required_permissions].blank? && permissions.present?
    definition
  end

  def registry_definition
    Captain::ToolRegistry.definition_for_class(self.class, scope_name: tool_scope_name) ||
      Captain::ToolRegistry.definition_for(name)
  end

  def audit_tool_execution(arguments:, result: nil, error: nil, runtime_context: {})
    Captain::ToolExecutionAuditService.record(
      assistant: assistant,
      scope_name: Captain::ToolAccess::SCOPE_AGENT,
      tool_definition: tool_definition,
      arguments: arguments,
      result: result,
      error: error,
      runtime_context: runtime_context
    )
  end

  def runtime_context(tool_context)
    state = tool_context&.context&.dig(:state) || {}
    conversation = state[:conversation] || {}

    {
      conversation_id: conversation[:id],
      conversation_display_id: conversation[:display_id],
      source: state[:source],
      current_agent: tool_context&.context&.[](:current_agent)
    }.compact
  end

  def account_scoped(model_class)
    model_class.where(account_id: @assistant.account_id)
  end

  def account
    assistant.account
  end

  def current_conversation(state)
    find_conversation(state)
  end

  def find_conversation(state)
    conversation_id = state&.dig(:conversation, :id)
    return nil unless conversation_id

    account_scoped(::Conversation).find_by(id: conversation_id)
  end

  def current_contact(state)
    find_contact(state)
  end

  def find_contact(state)
    contact_id = state&.dig(:contact, :id)
    return nil unless contact_id

    account_scoped(::Contact).find_by(id: contact_id)
  end

  def current_company(state)
    current_contact(state)&.company
  end

  def current_deal(state)
    deal_id = state&.dig(:deal, :id)
    return nil unless deal_id

    account.crm_deals.find_by(id: deal_id)
  end

  def current_task(state)
    task_id = state&.dig(:task, :id)
    return nil unless task_id

    account.crm_tasks.find_by(id: task_id)
  end

  def current_appointment(state)
    appointment_id = state&.dig(:appointment, :id)
    return nil unless appointment_id

    account.scheduling_appointments.find_by(id: appointment_id)
  end

  def feature_enabled?(feature_name)
    account.feature_enabled?(feature_name)
  end

  def ensure_feature_enabled!(feature_name, message)
    raise ArgumentError, message unless feature_enabled?(feature_name)
  end

  def bootstrap_crm_defaults!
    ::Crm::Bootstrap::AccountService.new(account: account).perform
  end

  def parse_json_hash(value, field_name:)
    return {} if value.blank?
    return value if value.is_a?(Hash)

    parsed = JSON.parse(value.to_s)
    raise ArgumentError, "#{field_name} must be a JSON object" unless parsed.is_a?(Hash)

    parsed
  rescue JSON::ParserError
    raise ArgumentError, "#{field_name} must be valid JSON"
  end

  def log_tool_usage(action, details = {})
    Rails.logger.info do
      "#{self.class.name}: #{action} for assistant #{@assistant&.id} - #{details.inspect}"
    end
  end
end
