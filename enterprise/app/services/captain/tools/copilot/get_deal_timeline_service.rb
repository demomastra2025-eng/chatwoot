class Captain::Tools::Copilot::GetDealTimelineService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'get_deal_timeline'
  end

  description 'Get the timeline for a CRM deal'
  param :deal_id, type: :number, desc: 'The deal ID', required: true
  param :limit, type: :number, desc: 'Maximum number of timeline items', required: false

  def execute(deal_id:, limit: nil)
    deal = account.crm_deals.find_by(id: deal_id)
    return 'Deal not found' if deal.blank?

    timeline = ::Crm::Timelines::DealService.new(
      account: account,
      deal: deal,
      actor: @user,
      params: { limit: limit }.compact
    ).perform

    formatted_payload(
      deal_id: deal.id,
      items: timeline[:items],
      meta: timeline[:meta]
    )
  end

  def active?
    feature_enabled?('crm_deals') && (user_has_permission('crm_deal_view') || user_has_permission('crm_deal_manage'))
  end
end
