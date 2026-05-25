# frozen_string_literal: true

class Captain::Tools::Copilot::ListAutomationRulesService < Captain::Tools::Copilot::AutomationRuleAdminTool
  def self.name
    'list_automation_rules'
  end

  description 'List account automation rules with safe metadata and redacted action details'
  param :query, type: :string, desc: 'Optional partial match against automation rule name', required: false
  param :event_name, type: :string, desc: 'Optional automation event name filter', required: false
  param :active, type: :boolean, desc: 'Optional active/inactive filter', required: false
  param :include_config, type: :boolean, desc: 'Whether to include redacted conditions/actions. Defaults to false', required: false
  param :limit, type: :number, desc: 'Maximum number of rules to return', required: false

  def execute(query: nil, event_name: nil, active: nil, include_config: false, limit: nil)
    ensure_account_administrator!

    rules = filtered_rules(query: query, event_name: event_name, active: active)
    include_rule_config = cast_boolean(include_config, default: false)

    formatted_payload(
      action: 'list_automation_rules',
      filters: { query: query, event_name: event_name, active: active }.compact,
      total_count: rules.count,
      supported_event_names: AutomationRule::SUPPORTED_EVENT_NAMES,
      rules: rules.limit(parse_limit(limit)).map { |rule| automation_rule_payload(rule, include_config: include_rule_config) }
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def filtered_rules(query:, event_name:, active:)
    rules = account.automation_rules.order(updated_at: :desc, id: :desc)
    rules = rules.where('LOWER(name) ILIKE :query', query: "%#{query.to_s.downcase}%") if query.present?
    rules = rules.where(event_name: event_name) if event_name.present?
    rules = rules.where(active: cast_boolean(active)) unless active.nil?
    rules
  end
end
