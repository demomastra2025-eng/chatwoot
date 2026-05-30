class Captain::Tools::Copilot::SearchDealsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_deals'
  end

  description 'Search CRM deals by current conversation contact, title, pipeline, stage, owner, company, or explicit contact. In a conversation, defaults to deals for the current contact.'
  param :query, type: :string, desc: 'Deal title or external reference query', required: false
  param :contact_id,
        type: :integer,
        desc: 'Positive contact ID. Omit when unknown; defaults to the current conversation contact when available.',
        required: false
  param :pipeline_id, type: :integer, desc: 'Positive pipeline ID from list_deal_pipelines. Omit when unknown.', required: false
  param :pipeline_code, type: :string, desc: 'Pipeline code from list_deal_pipelines', required: false
  param :stage_id, type: :integer, desc: 'Positive stage ID from list_deal_stages/list_deal_pipelines. Omit when unknown.', required: false
  param :stage_name, type: :string, desc: 'Stage name; use with pipeline_id/pipeline_code when names repeat across pipelines', required: false
  param :stage_code, type: :string, desc: 'Stage code; use with pipeline_id/pipeline_code when codes repeat across pipelines', required: false
  param :owner_id, type: :integer, desc: 'Positive owner user ID. Omit when unknown.', required: false
  param :company_id, type: :integer, desc: 'Positive company ID. Omit when unknown.', required: false
  param :archived, type: :boolean, desc: 'Whether to search archived deals', required: false
  param :limit, type: :number, desc: 'Maximum number of deals to return', required: false

  def execute(query: nil, contact_id: nil, pipeline_id: nil, pipeline_code: nil, stage_id: nil, stage_name: nil, stage_code: nil,
              owner_id: nil, company_id: nil, archived: nil, limit: nil)
    query = query.to_s.strip.presence
    contact_id = optional_positive_id(contact_id)
    pipeline_id = optional_positive_id(pipeline_id)
    stage_id = optional_positive_id(stage_id)
    owner_id = optional_positive_id(owner_id)
    company_id = optional_positive_id(company_id)
    scoped_contact_id = contact_id || current_contact&.id

    deals = account.crm_deals.includes(:pipeline, :stage, :owner, :team, :company, :deal_contacts)
    deals = cast_boolean(archived) ? deals.archived : deals.kept
    deals = apply_contact_filter(deals, scoped_contact_id)
    deals = apply_pipeline_filter(deals, pipeline_id: pipeline_id, pipeline_code: pipeline_code)
    deals = apply_stage_filter(deals, stage_id: stage_id, stage_name: stage_name, stage_code: stage_code)
    deals = deals.where(owner_id: owner_id) if owner_id.present?
    deals = deals.where(company_id: company_id) if company_id.present?
    deals = deals.where('crm_deals.title ILIKE :query OR crm_deals.external_ref ILIKE :query', query: "%#{query}%") if query.present?

    total_count = deals.count
    records = deals.ordered.limit(parse_limit(limit)).map { |deal| Crm::PayloadBuilder.ai_deal(deal) }

    formatted_payload(
      filters: {
        query: query,
        contact_id: contact_id,
        current_contact_id: contact_id.blank? ? scoped_contact_id : nil,
        pipeline_id: pipeline_id,
        pipeline_code: pipeline_code,
        stage_id: stage_id,
        stage_name: stage_name,
        stage_code: stage_code,
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

  private

  def apply_contact_filter(deals, contact_id)
    return deals if contact_id.blank?

    deals.where(id: ::Crm::DealContact.where(contact_id: contact_id).select(:deal_id))
  end

  def apply_pipeline_filter(deals, pipeline_id:, pipeline_code:)
    return deals.where(pipeline_id: pipeline_id) if pipeline_id.present?
    return deals.joins(:pipeline).where(crm_pipelines: { code: normalized_code(pipeline_code) }) if pipeline_code.present?

    deals
  end

  def apply_stage_filter(deals, stage_id:, stage_name:, stage_code:)
    return deals.where(stage_id: stage_id) if stage_id.present?
    return deals.joins(:stage).where(crm_stages: { code: normalized_code(stage_code) }) if stage_code.present?
    return deals.joins(:stage).where('LOWER(crm_stages.name) = ?', stage_name.to_s.strip.downcase) if stage_name.present?

    deals
  end

  def normalized_code(value)
    ::Crm::CodeNormalizer.normalize(value)
  end
end
