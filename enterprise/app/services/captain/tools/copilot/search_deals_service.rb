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
    contact_id = verified_optional_record_id(contact_id, scope: account.contacts, field_name: 'contact_id')
    pipeline = resolve_pipeline(pipeline_id: pipeline_id, pipeline_code: pipeline_code)
    stage = resolve_stage(stage_id: stage_id, stage_name: stage_name, stage_code: stage_code, pipeline: pipeline)
    owner_id = verified_optional_record_id(owner_id, scope: account.users, field_name: 'owner_id')
    company_id = verified_optional_record_id(company_id, scope: account.companies, field_name: 'company_id')
    scoped_contact_id = contact_id || current_contact&.id

    deals = account.crm_deals.includes(:pipeline, :stage, :owner, :team, :company, :deal_contacts)
    deals = cast_boolean(archived) ? deals.archived : deals.kept
    deals = apply_contact_filter(deals, scoped_contact_id)
    deals = deals.where(pipeline_id: pipeline.id) if pipeline.present?
    deals = deals.where(stage_id: stage.id) if stage.present?
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
        pipeline_id: pipeline&.id,
        pipeline_code: pipeline&.code,
        stage_id: stage&.id,
        stage_name: stage&.name,
        stage_code: stage&.code,
        owner_id: owner_id,
        company_id: company_id,
        archived: cast_boolean(archived)
      }.compact,
      total_count: total_count,
      deals: records
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    feature_enabled?('crm_deals') && (user_has_permission('crm_deal_view') || user_has_permission('crm_deal_manage'))
  end

  private

  def apply_contact_filter(deals, contact_id)
    return deals if contact_id.blank?

    deals.where(id: ::Crm::DealContact.where(contact_id: contact_id).select(:deal_id))
  end

  def resolve_pipeline(pipeline_id:, pipeline_code:)
    if pipeline_code.present?
      normalized_pipeline_code = normalized_code(pipeline_code)
      return account.crm_pipelines.find_by(code: normalized_pipeline_code) ||
             raise(ArgumentError, "Unknown pipeline_code #{pipeline_code}. Use a value returned by list_deal_pipelines.")
    end

    verified_pipeline_id = verified_optional_record_id(pipeline_id, scope: account.crm_pipelines, field_name: 'pipeline_id')
    account.crm_pipelines.find(verified_pipeline_id) if verified_pipeline_id.present?
  end

  def resolve_stage(stage_id:, stage_name:, stage_code:, pipeline:)
    scope = account.crm_stages
    scope = scope.where(pipeline_id: pipeline.id) if pipeline.present?
    return resolve_stage_by_name(scope, stage_name) if stage_name.present?
    return resolve_stage_by_code(scope, stage_code) if stage_code.present?

    verified_stage_id = verified_optional_record_id(stage_id, scope: scope, field_name: 'stage_id')
    scope.find(verified_stage_id) if verified_stage_id.present?
  end

  def resolve_stage_by_name(scope, stage_name)
    resolve_unique_stage(scope.where('LOWER(name) = ?', stage_name.to_s.strip.downcase), "stage_name #{stage_name}")
  end

  def resolve_stage_by_code(scope, stage_code)
    resolve_unique_stage(scope.where(code: normalized_code(stage_code)), "stage_code #{stage_code}")
  end

  def resolve_unique_stage(scope, selector)
    matches = scope.order(:id).limit(2).to_a
    raise ArgumentError, "Unknown #{selector}. Use a value returned by list_deal_stages." if matches.empty?
    raise ArgumentError, "Ambiguous #{selector}; also provide pipeline_code or a verified pipeline_id." if matches.many?

    matches.first
  end

  def normalized_code(value)
    ::Crm::CodeNormalizer.normalize(value)
  end
end
