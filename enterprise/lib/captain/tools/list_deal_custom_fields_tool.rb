class Captain::Tools::ListDealCustomFieldsTool < Captain::Tools::BasePublicTool
  description 'List active allowed CRM custom fields for deal custom_attributes, including key, label, type, required flag, and select options.'

  def perform(_tool_context)
    fields = Captain::Tools::CrmCustomFieldCatalog.new(
      account: account,
      entity_kind: 'deal'
    ).fields

    JSON.pretty_generate(
      action: 'list_deal_custom_fields',
      entity_kind: 'deal',
      returned_count: fields.length,
      fields: fields
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    feature_enabled?('crm_deals')
  end
end
