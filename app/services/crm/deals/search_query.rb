class Crm::Deals::SearchQuery
  SEARCH_SQL = <<~SQL.squish.freeze
    CAST(crm_deals.id AS TEXT) ILIKE :query OR
    crm_deals.title ILIKE :query OR
    crm_deals.description ILIKE :query OR
    crm_deals.external_ref ILIKE :query OR
    crm_deals.currency ILIKE :query OR
    CAST(crm_deals.amount_minor AS TEXT) ILIKE :numeric_query OR
    CAST(crm_deals.amount_minor::numeric / 100 AS TEXT) ILIKE :numeric_query OR
    EXISTS (
      SELECT 1 FROM companies
      WHERE companies.id = crm_deals.company_id
        AND companies.account_id = crm_deals.account_id
        AND companies.name ILIKE :query
    ) OR
    EXISTS (
      SELECT 1
      FROM crm_deal_contacts
      INNER JOIN contacts ON contacts.id = crm_deal_contacts.contact_id
      WHERE crm_deal_contacts.deal_id = crm_deals.id
        AND crm_deal_contacts.primary = TRUE
        AND contacts.account_id = crm_deals.account_id
        AND contacts.name ILIKE :query
    ) OR
    EXISTS (
      SELECT 1 FROM crm_pipelines
      WHERE crm_pipelines.id = crm_deals.pipeline_id
        AND crm_pipelines.account_id = crm_deals.account_id
        AND crm_pipelines.name ILIKE :query
    ) OR
    EXISTS (
      SELECT 1 FROM crm_stages
      WHERE crm_stages.id = crm_deals.stage_id
        AND crm_stages.account_id = crm_deals.account_id
        AND crm_stages.name ILIKE :query
    ) OR
    EXISTS (
      SELECT 1 FROM users
      WHERE users.id = crm_deals.owner_id
        AND (users.name ILIKE :query OR users.email ILIKE :query)
    )
  SQL

  def initialize(scope:, params:)
    @scope = scope
    @params = params
  end

  def perform
    return scope if params[:q].blank?

    raw_query = params[:q].to_s.strip.first(200)
    bindings = custom_field_search_bindings(raw_query).merge(
      numeric_query: search_pattern(raw_query.delete(" \u00A0").tr(',', '.')),
      query: search_pattern(raw_query.delete_prefix('#'))
    )
    clauses = [SEARCH_SQL, ::Crm::Deals::CustomFieldSearchQuery::SQL]
    scope.where(clauses.join(' OR '), bindings)
  end

  private

  attr_reader :params, :scope

  def custom_field_search_bindings(raw_query)
    date_alias = valid_search_alias(:q_date_alias, /\A\d{4}-\d{2}-\d{2}\z/)
    datetime_alias = datetime_search_alias
    {
      checked_alias: ActiveModel::Type::Boolean.new.cast(params[:q_checked]),
      date_alias: date_alias,
      date_alias_pattern: "#{date_alias}%",
      datetime_alias: datetime_alias,
      numeric_alias: numeric_search_alias(raw_query).to_s,
      percent_alias: percent_search_alias(raw_query).to_s
    }
  end

  def search_pattern(term)
    "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
  end

  def valid_search_alias(param_name, pattern)
    value = params[param_name].to_s
    value.match?(pattern) ? value : ''
  end

  def numeric_search_alias(raw_query)
    return if raw_query.include?('%')

    frontend_alias = params[:q_numeric_alias].to_s
    return frontend_alias if frontend_alias.match?(/\A-?\d+(?:\.\d+)?\z/)

    normalized = raw_query.delete(" \u00A0").tr(',', '.')
    normalized if normalized.match?(/\A-?\d+(?:\.\d+)?\z/)
  end

  def datetime_search_alias
    value = params[:q_datetime_alias].to_s
    return '' unless value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}Z\z/)

    Time.iso8601(value.sub(/Z\z/, ':00Z'))
    value
  rescue ArgumentError
    ''
  end

  def percent_search_alias(raw_query)
    normalized = raw_query.delete(" \u00A0").tr(',', '.')
    match = normalized.match(/\A(-?\d+(?:\.\d+)?)%\z/)
    match[1] if match
  end
end
