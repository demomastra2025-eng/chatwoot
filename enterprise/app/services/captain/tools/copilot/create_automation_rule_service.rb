# frozen_string_literal: true

class Captain::Tools::Copilot::CreateAutomationRuleService < Captain::Tools::Copilot::AutomationRuleAdminTool
  def self.name
    'create_automation_rule'
  end

  description 'Create an account automation rule from explicit event, conditions JSON, and actions JSON'
  param :name, type: :string, desc: 'Automation rule name', required: true
  param :event_name, type: :string, desc: "Automation event name. Use one of: #{AutomationRule::SUPPORTED_EVENT_NAMES.join(', ')}", required: true
  param :conditions_json, type: :string, desc: 'JSON array of automation rule conditions', required: false
  param :actions_json, type: :string, desc: 'JSON array of automation rule actions', required: false
  param :description, type: :string, desc: 'Optional automation rule description', required: false
  param :active, type: :boolean, desc: 'Whether the rule starts active. Defaults to true', required: false

  def execute(name:, event_name:, **kwargs)
    ensure_account_administrator!

    rule = account.automation_rules.new(
      build_rule_attributes(name: name, description: kwargs[:description], event_name: event_name, active: kwargs.fetch(:active, true))
    )
    rule.conditions = parse_json_array(kwargs.fetch(:conditions_json, '[]'), field_name: 'conditions_json')
    rule.actions = parse_json_array(kwargs.fetch(:actions_json, '[]'), field_name: 'actions_json')
    save_rule!(rule)

    formatted_payload(action: 'create_automation_rule', rule: automation_rule_payload(rule, include_config: true))
  rescue StandardError => e
    tool_failure(e)
  end
end
