class CrmAutomationRuleListener < BaseListener
  DEAL_EVENT_NAMES = %w[
    deal_created
    deal_updated
    deal_stage_changed
    deal_archived
    deal_unarchived
  ].freeze
  TASK_EVENT_NAMES = %w[
    task_created
    task_updated
    task_status_changed
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

    matching_rules_for_event(
      event_name,
      account,
      record,
      entity_kind,
      event.data[:changed_attributes]
    ).each do |rule|
      live_record = record_scope(account, entity_kind).find_by(id: record.id)
      next if live_record.blank?

      AutomationRules::CrmActionService.new(
        rule,
        account,
        live_record,
        entity_kind: entity_kind,
        options: { changed_attributes: event.data[:changed_attributes] }
      ).perform
    end
  end

  def matching_rules_for_event(event_name, account, record, entity_kind, changed_attributes)
    snapshot = record_snapshot(account, record, entity_kind)

    current_account_rules(event_name, account).filter_map do |rule|
      conditions_match = AutomationRules::CrmConditionService.new(
        rule,
        snapshot,
        entity_kind: entity_kind,
        options: { changed_attributes: changed_attributes }
      ).perform

      rule if conditions_match
    end
  end

  def current_account_rules(event_name, account)
    AutomationRule.where(
      event_name: event_name,
      account_id: account.id,
      active: true
    )
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

  def record_snapshot(account, record, entity_kind)
    record_scope(account, entity_kind).find_by(id: record.id) || record
  end
end
