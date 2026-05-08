class Captain::Tools::Copilot::GetDealService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'get_deal'
  end

  description 'Get details of a CRM deal'
  param :deal_id, type: :number, desc: 'The deal ID', required: true

  def execute(deal_id:)
    deal = account.crm_deals.includes(:pipeline, :stage, :owner, :team, :company, :contacts).find_by(id: deal_id)
    return 'Deal not found' if deal.blank?

    formatted_payload(deal: ::Crm::PayloadBuilder.ai_deal(deal))
  end

  def active?
    feature_enabled?('crm_deals') && (user_has_permission('crm_deal_view') || user_has_permission('crm_deal_manage'))
  end
end
