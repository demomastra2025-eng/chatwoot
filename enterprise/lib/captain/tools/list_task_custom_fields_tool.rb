class Captain::Tools::ListTaskCustomFieldsTool < Captain::Tools::BasePublicTool
  description 'List active allowed CRM custom fields for task custom_attributes, including key, label, type, required flag, and select options.'
  param :context_kind,
        type: 'string',
        desc: 'Optional task context: sales or personal. Defaults to the current task or deal context.',
        required: false

  def perform(tool_context, context_kind: nil)
    fields = Captain::Tools::CrmCustomFieldCatalog.new(
      account: account,
      entity_kind: 'task',
      context: task_field_context(tool_context&.state || {}, context_kind)
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

  def task_field_context(state, context_kind)
    return ::Crm::Task.custom_field_context_for(context_kind) if context_kind.present?

    task = current_task(state)
    return task.custom_field_context if task.present?

    current_deal(state).present? ? 'deal_task' : 'standalone_task'
  end
end
