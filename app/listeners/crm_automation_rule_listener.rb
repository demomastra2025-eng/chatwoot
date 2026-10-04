class CrmAutomationRuleListener < BaseListener
  DEAL_EVENT_NAMES = %w[
    deal_created
    deal_updated
    deal_stage_changed
    deal_waiting_set
    deal_waiting_cleared
    deal_archived
    deal_unarchived
  ].freeze
  LEGACY_TASK_EVENT_NAMES = {
    'task_completed' => 'task_status_changed',
    'task_cancelled' => 'task_status_changed',
    'task_reopened' => 'task_status_changed',
    'task_assigned' => 'task_updated',
    'task_rescheduled' => 'task_updated',
    'task_waiting_changed' => 'task_updated',
    'task_archived' => 'task_updated',
    'task_unarchived' => 'task_updated'
  }.freeze
  TASK_EVENT_NAMES = %w[
    task_created
    task_updated
    task_status_changed
    task_assigned
    task_rescheduled
    task_completed
    task_cancelled
    task_reopened
    task_waiting_changed
    task_archived
    task_unarchived
  ].freeze

  DEAL_EVENT_NAMES.each do |event_name|
    define_method(event_name) do |event|
      process_crm_event(event, event_name, 'deal')
    end
  end

  TASK_EVENT_NAMES.each do |event_name|
    define_method(event_name) do |event|
      process_crm_event(event, event_name, 'task')
    end
  end

  private

  def process_crm_event(event, event_name, entity_kind)
    return if performed_by_automation?(event)

    record, account = extract_record_and_account(event, entity_kind)
    return unless record.present? && account.present?

    perform_matching_rules(event, event_name, record, account, entity_kind)
  end

  def perform_matching_rules(event, event_name, record, account, entity_kind)
    event_context = {
      event: event,
      event_name: event_name,
      account: account,
      record: record,
      entity_kind: entity_kind,
      changed_attributes: event.data[:changed_attributes]
    }
    matching_rules_for_event(event_context).each do |rule|
      perform_rule(event, rule, record, account, entity_kind)
    end
  end

  def perform_rule(event, rule, record, account, entity_kind)
    live_record = record_scope(account, entity_kind).find_by(id: record.id)
    return if live_record.blank?

    AutomationRules::CrmActionService.new(
      rule,
      account,
      live_record,
      entity_kind: entity_kind,
      options: {
        changed_attributes: event.data[:changed_attributes],
        source_snapshot: event.data[:automation_matching_snapshot]
      }
    ).perform
  end

  def matching_rules_for_event(event_context)
    snapshot = record_snapshot(event_context[:account], event_context[:record], event_context[:entity_kind])

    current_account_rules(event_rule_names(event_context), event_context[:account]).filter_map do |rule|
      conditions_match = AutomationRules::CrmConditionService.new(
        rule,
        snapshot,
        entity_kind: event_context[:entity_kind],
        options: {
          changed_attributes: event_context[:changed_attributes],
          snapshot: automation_snapshot(event_context[:event], event_context[:entity_kind])
        }
      ).perform

      rule if conditions_match
    end
  end

  def current_account_rules(event_names, account)
    AutomationRule.where(
      event_name: event_names,
      account_id: account.id,
      active: true
    ).order(:id)
  end

  def event_rule_names(event_context)
    event_name = event_context[:event_name]
    return [event_name] unless event_context[:entity_kind] == 'task'

    [event_name, LEGACY_TASK_EVENT_NAMES[event_name]].compact.uniq
  end

  def performed_by_automation?(event)
    event.data[:performed_by].present? && event.data[:performed_by].instance_of?(AutomationRule)
  end

  def extract_record_and_account(event, entity_kind)
    entity_kind == 'deal' ? extract_deal_and_account(event) : extract_task_and_account(event)
  end

  def record_scope(account, entity_kind)
    entity_kind == 'deal' ? account.crm_deals : account.crm_tasks
  end

  def automation_snapshot(event, entity_kind)
    payload = event.data[:automation_matching_snapshot].to_h.with_indifferent_access
    payload.dig(:matcher_data, entity_kind)&.with_indifferent_access
  end

  def record_snapshot(account, record, entity_kind)
    record_scope(account, entity_kind).find_by(id: record.id) || record
  end
end
