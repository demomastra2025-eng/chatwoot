class Captain::Tools::Account::GetDealService < Captain::Tools::Account::BaseAccountTool
  def self.name
    'get_deal'
  end

  description 'Get details of a CRM deal'
  param :deal_id, type: :number, desc: 'The deal ID', required: true

  def execute(deal_id:)
    deal_id = required_positive_id(deal_id, field_name: 'deal_id')
    deal = deal_scope.includes(:pipeline, :stage, :owner, :team, :company, :contacts).find_by(id: deal_id)
    return tool_failure('Deal not found') if deal.blank?

    formatted_payload(deal: ::Crm::PayloadBuilder.ai_deal(deal))
  end

  def active?
    feature_enabled?('crm_deals') && (user_has_permission('crm_deal_view') || user_has_permission('crm_deal_manage'))
  end

  private

  def deal_scope
    return account.crm_deals unless customer_agent_execution?

    Crm::Deals::ContactScope.resolve(account: account, contact: current_contact)
  end
end
