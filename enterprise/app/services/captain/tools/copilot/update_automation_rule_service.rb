# frozen_string_literal: true

class Captain::Tools::Copilot::UpdateAutomationRuleService < Captain::Tools::Copilot::AutomationRuleAdminTool
  def self.name
    'update_automation_rule'
  end

  description 'Update an account automation rule metadata, event, conditions, actions, or active status'
  param :automation_rule_id, type: :number, desc: 'Automation rule ID from list_automation_rules', required: true
  param :name, type: :string, desc: 'Optional automation rule name', required: false
  param :description, type: :string, desc: 'Optional automation rule description', required: false
  param :event_name, type: :string, desc: 'Optional automation event name', required: false
  param :conditions_json, type: :string, desc: 'Optional JSON array of automation rule conditions', required: false
  param :actions_json, type: :string, desc: 'Optional JSON array of automation rule actions', required: false
  param :active, type: :boolean, desc: 'Optional active flag', required: false

  def execute(automation_rule_id:, **kwargs)
    ensure_account_administrator!

    rule = automation_rule!(automation_rule_id)
    apply_rule_updates!(rule, kwargs)
    save_rule!(rule)

    formatted_payload(action: 'update_automation_rule', rule: automation_rule_payload(rule.reload, include_config: true))
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def apply_rule_updates!(rule, kwargs)
    attrs = build_rule_attributes(**kwargs.slice(:name, :description, :event_name, :active))
    rule.assign_attributes(attrs) if attrs.present?
    rule.conditions = parse_json_array(kwargs[:conditions_json], field_name: 'conditions_json') if kwargs.key?(:conditions_json)
    rule.actions = parse_json_array(kwargs[:actions_json], field_name: 'actions_json') if kwargs.key?(:actions_json)
    raise ArgumentError, 'No supported automation rule fields were provided' if attrs.blank? && kwargs.slice(:conditions_json, :actions_json).blank?
  end
end
