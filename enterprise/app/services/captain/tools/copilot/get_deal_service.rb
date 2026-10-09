class Captain::Tools::Copilot::GetDealService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'get_deal'
  end

  description 'Get details of a CRM deal'
  param :deal_id, type: :number, desc: 'The deal ID', required: true

  def execute(deal_id:)
    deal_id = required_positive_id(deal_id, field_name: 'deal_id')
    deals = patient_scope ? patient_scope.deals : account.crm_deals
    deal = deals.includes(:pipeline, :stage, :owner, :team, :company, :contacts).find_by(id: deal_id)
    return patient_scope ? Captain::Tools::Agent::PatientScope::FAILURE : tool_failure('Deal not found') if deal.blank?

    formatted_payload(deal: patient_scope ? patient_scope.deal_payload(deal) : ::Crm::PayloadBuilder.ai_deal(deal))
  end

  def active?
    feature_enabled?('crm_deals') && (user_has_permission('crm_deal_view') || user_has_permission('crm_deal_manage'))
  end
end
