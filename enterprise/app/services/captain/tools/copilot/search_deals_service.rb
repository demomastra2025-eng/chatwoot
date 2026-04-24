class Captain::Tools::Copilot::SearchDealsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_deals'
  end

  description 'Search CRM deals by title, stage, owner, or company'
  param :query, type: :string, desc: 'Deal title or external reference query', required: false
  param :stage_name, type: :string, desc: 'Stage name', required: false
  param :owner_id, type: :number, desc: 'Owner user ID', required: false
  param :company_id, type: :number, desc: 'Company ID', required: false
  param :archived, type: :boolean, desc: 'Whether to search archived deals', required: false
  param :limit, type: :number, desc: 'Maximum number of deals to return', required: false

  def execute(query: nil, stage_name: nil, owner_id: nil, company_id: nil, archived: nil, limit: nil)
    deals = account.crm_deals.includes(:pipeline, :stage, :owner, :team, :company, :deal_contacts)
    deals = cast_boolean(archived) ? deals.archived : deals.kept
    deals = deals.where(owner_id: owner_id) if owner_id.present?
    deals = deals.where(company_id: company_id) if company_id.present?
    deals = deals.joins(:stage).where('LOWER(crm_stages.name) = ?', stage_name.to_s.downcase) if stage_name.present?
    deals = deals.where('crm_deals.title ILIKE :query OR crm_deals.external_ref ILIKE :query', query: "%#{query.strip}%") if query.present?

    total_count = deals.count
    records = deals.ordered.limit(parse_limit(limit)).map { |deal| Crm::PayloadBuilder.deal(deal) }

    formatted_payload(
      filters: {
        query: query,
        stage_name: stage_name,
        owner_id: owner_id,
        company_id: company_id,
        archived: cast_boolean(archived)
      }.compact,
      total_count: total_count,
      deals: records
    )
  end

  def active?
    feature_enabled?('crm_deals') && (user_has_permission('crm_deal_view') || user_has_permission('crm_deal_manage'))
  end
end
