class Captain::Tools::ListTaskCustomFieldsTool < Captain::Tools::BasePublicTool
  description 'List active allowed CRM custom fields for task custom_attributes, including key, label, type, required flag, and select options.'

  def perform(tool_context)
    fields = Captain::Tools::CrmCustomFieldCatalog.new(
      account: account,
      entity_kind: 'task',
      context: task_field_context(tool_context&.state || {})
    ).fields

    JSON.pretty_generate(
      action: 'list_task_custom_fields',
      entity_kind: 'task',
      returned_count: fields.length,
      fields: fields
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    feature_enabled?('crm_tasks')
  end

  private

  def task_field_context(state)
    task = current_task(state)
    deal = task&.deal || current_deal(state)

    deal.present? ? 'deal_task' : 'standalone_task'
  end
end
