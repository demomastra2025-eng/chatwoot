class Captain::Tools::Copilot::ListTaskCustomFieldsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'list_task_custom_fields'
  end

  description 'List active allowed CRM custom fields for task custom_attributes, including key, label, type, required flag, and select options.'
  param :context_kind,
        type: :string,
        desc: 'Optional task context: sales or personal. Defaults to the current task or deal context.',
        required: false

  def execute(context_kind: nil)
    fields = Captain::Tools::CrmCustomFieldCatalog.new(
      account: account,
      entity_kind: 'task',
      context: task_field_context(context_kind)
    ).fields

    formatted_payload(
      action: 'list_task_custom_fields',
      entity_kind: 'task',
      returned_count: fields.length,
      fields: fields
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    feature_enabled?('crm_tasks') && readable_or_manageable?
  end

  private

  def task_field_context(context_kind)
    return ::Crm::Task.custom_field_context_for(context_kind) if context_kind.present?
    return current_task.custom_field_context if current_task.present?

    current_deal.present? ? 'deal_task' : 'standalone_task'
  end

  def readable_or_manageable?
    case 'task'
    when 'deal'
      user_has_permission('crm_deal_view') || user_has_permission('crm_deal_manage')
    when 'task'
      user_has_permission('crm_task_view') || user_has_permission('crm_task_manage')
    else
      @user.present?
    end
  end
end
