class Captain::Tools::Copilot::ListTaskCustomFieldsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'list_task_custom_fields'
  end

  description 'List active allowed CRM custom fields for task custom_attributes, including key, label, type, required flag, and select options.'

  def execute
    fields = Captain::Tools::CrmCustomFieldCatalog.new(
      account: account,
      entity_kind: 'task',
      context: task_field_context
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

  def task_field_context
    deal = current_task&.deal || current_deal

    deal.present? ? 'deal_task' : 'standalone_task'
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
