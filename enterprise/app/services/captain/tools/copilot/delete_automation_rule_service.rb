# frozen_string_literal: true

class Captain::Tools::Copilot::DeleteAutomationRuleService < Captain::Tools::Copilot::AutomationRuleAdminTool
  def self.name
    'delete_automation_rule'
  end

  description 'Delete an account automation rule so it no longer runs'
  param :automation_rule_id, type: :number, desc: 'Automation rule ID from list_automation_rules', required: true

  def execute(automation_rule_id:)
    ensure_account_administrator!

    rule = automation_rule!(automation_rule_id)
    payload = automation_rule_payload(rule, include_config: false)
    rule.destroy!

    formatted_payload(action: 'delete_automation_rule', deleted: true, rule: payload)
  rescue StandardError => e
    tool_failure(e)
  end
end
