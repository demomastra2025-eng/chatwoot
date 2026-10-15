class Captain::Tools::Account::ListMyDealsService < Captain::Tools::Account::BaseAccountTool
  STATUSES = %w[open won lost any].freeze

  def self.name
    'list_my_deals'
  end

  description 'List CRM deals linked to the current conversation contact'
  param :status, type: :string, desc: 'open, won, lost, or any', required: false
  param :pipeline, type: :string, desc: 'Pipeline name or code', required: false
  param :limit, type: :number, desc: 'Page size, at most 20', required: false
  param :offset, type: :number, desc: 'Number of records to skip', required: false

  def execute(status: 'any', pipeline: nil, limit: nil, offset: nil)
    return formatted_payload(success: false, reason: 'not_found') unless contact_available?

    page = { limit: validated_limit(limit), offset: parse_offset(offset) }
    deals = filtered_deals(status, pipeline)

    total = deals.count
    records = deals.reorder(updated_at: :desc, id: :desc).offset(page[:offset]).limit(page[:limit]).includes(:pipeline, :stage)
    formatted_payload(
      success: true, total: total, **page,
      has_more: page[:offset] + page[:limit] < total,
      deals: records.map { |deal| card(deal) }
    )
  rescue ArgumentError
    formatted_payload(success: false, reason: 'validation_error')
  end

  def active?
    feature_enabled?('crm_deals') && (user_has_permission('crm_deal_view') || user_has_permission('crm_deal_manage'))
  end

  private

  def contact_available?
    patient_scope ? patient_scope.contact_id.present? : current_contact.present?
  end

  def filtered_deals(status, pipeline)
    status = status.to_s.presence || 'any'
    raise ArgumentError, 'Invalid status' unless STATUSES.include?(status)

    scope = patient_scope ? patient_scope.deals : Captain::DealContext.new(account: account, conversation: current_conversation).deals
    scope = scope.joins(:stage)
    scope = scope.where(Captain::DealContext::ACTIVE_SQL) if status == 'open'
    scope = scope.where(crm_stages: { outcome: status }) if %w[won lost].include?(status)
    filter_pipeline(scope, pipeline)
  end

  def validated_limit(value)
    return 10 if value.nil?

    text = value.is_a?(Float) && value.finite? && value == value.floor ? value.to_i.to_s : value.to_s.strip
    raise ArgumentError, 'Invalid limit' unless text.match?(/\A[1-9]\d*\z/)

    [text.to_i, 20].min
  end

  def filter_pipeline(deals, value)
    return deals if value.blank?

    selector = value.to_s.strip
    pipelines = if selector.match?(/\A[1-9]\d*\z/)
                  account.crm_pipelines.where(id: selector.to_i)
                else
                  account.crm_pipelines.where('LOWER(name) = :value OR LOWER(code) = :value', value: selector.downcase)
                end
    deals.where(pipeline_id: pipelines.select(:id))
  end

  def card(deal)
    zone = Time.find_zone(account.reporting_timezone) || Time.zone
    status = if %w[won lost].include?(deal.stage.outcome)
               deal.stage.outcome
             elsif deal.archived_at.present?
               'archived'
             elsif deal.closed_at.present?
               'closed'
             else
               'open'
             end
    {
      id: deal.id, title: deal.title, pipeline: deal.pipeline.name, stage: deal.stage.name,
      status: status, amount: Crm::AmountFormatter.major_from_minor(deal.amount_minor),
      currency: deal.currency, updated_at: deal.updated_at.in_time_zone(zone).iso8601
    }
  end
end
