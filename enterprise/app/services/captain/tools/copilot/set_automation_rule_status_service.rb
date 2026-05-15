# frozen_string_literal: true

class Captain::Tools::Copilot::SetAutomationRuleStatusService < Captain::Tools::Copilot::AutomationRuleAdminTool
  def self.name
    'set_automation_rule_status'
  end

  description 'Pause or resume an account automation rule by setting its active flag'
  param :automation_rule_id, type: :number, desc: 'Automation rule ID from list_automation_rules', required: true
  param :active, type: :boolean, desc: 'True to resume, false to pause', required: true

  def execute(automation_rule_id:, active:)
    ensure_account_administrator!

    rule = automation_rule!(automation_rule_id)
    rule.update!(active: cast_boolean(active))

    formatted_payload(action: 'set_automation_rule_status', rule: automation_rule_payload(rule.reload, include_config: false))
  rescue StandardError => e
    tool_failure(e)
  end
end
