# frozen_string_literal: true

class Captain::Tools::Copilot::GetAutomationRuleService < Captain::Tools::Copilot::AutomationRuleAdminTool
  def self.name
    'get_automation_rule'
  end

  description 'Get one account automation rule with redacted conditions/actions'
  param :automation_rule_id, type: :number, desc: 'Automation rule ID from list_automation_rules', required: true

  def execute(automation_rule_id:)
    ensure_account_administrator!

    rule = automation_rule!(automation_rule_id)

    formatted_payload(
      action: 'get_automation_rule',
      rule: automation_rule_payload(rule, include_config: true),
      supported_conditions: rule.conditions_attributes,
      supported_actions: rule.actions_attributes
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
