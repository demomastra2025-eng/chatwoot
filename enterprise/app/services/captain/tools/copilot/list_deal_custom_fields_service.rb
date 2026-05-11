class Captain::Tools::Copilot::ListDealCustomFieldsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'list_deal_custom_fields'
  end

  description 'List active allowed CRM custom fields for deal custom_attributes, including key, label, type, required flag, and select options.'

  def execute
    fields = Captain::Tools::CrmCustomFieldCatalog.new(
      account: account,
      entity_kind: 'deal'
    ).fields

    formatted_payload(
      action: 'list_deal_custom_fields',
      entity_kind: 'deal',
      returned_count: fields.length,
      fields: fields
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    feature_enabled?('crm_deals') && readable_or_manageable?
  end

  private

  def readable_or_manageable?
    case 'deal'
    when 'deal'
      user_has_permission('crm_deal_view') || user_has_permission('crm_deal_manage')
    when 'task'
      user_has_permission('crm_task_view') || user_has_permission('crm_task_manage')
    else
      @user.present?
    end
  end
end
