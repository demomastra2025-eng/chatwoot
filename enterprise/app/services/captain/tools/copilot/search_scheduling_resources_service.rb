class Captain::Tools::Copilot::SearchSchedulingResourcesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_scheduling_resources'
  end

  description 'Search scheduling resources by stored name/specialty; service price links are not clinical proof'
  param :query, type: :string, desc: 'Resource name or stored specialty query', required: false
  param :search_by, type: :string, desc: 'Search mode: name, specialty, or all', required: false
  param :service_id, type: :number, desc: 'Optional service ID to filter recorded active price links (not clinical eligibility)', required: false
  param :include_inactive, type: :boolean, desc: 'Whether to include inactive resources', required: false
  param :limit, type: :number, desc: 'Maximum number of specialists to return', required: false
  param :offset, type: :number, desc: 'Pagination offset for matching resources', required: false

  def execute(query: nil, search_by: 'all', service_id: nil, include_inactive: false, limit: nil, offset: nil) # rubocop:disable Metrics/ParameterLists
    service_id = verified_optional_record_id(service_id, scope: account.scheduling_services, field_name: 'service_id')
    offset = parse_offset(offset)
    result = Scheduling::ResourceSearchService.new(
      account: account,
      query: query,
      search_by: search_by,
      service_id: service_id,
      include_inactive: include_inactive,
      limit: parse_limit(limit),
      offset: offset
    ).perform

    filters = { query: query.to_s.presence, search_by: search_by.to_s.presence || 'all', service_id: service_id,
                include_inactive: cast_boolean(include_inactive), offset: offset }.compact
    formatted_search_payload(result, filters)
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end

  private

  def formatted_search_payload(result, filters)
    status = search_status(result[:total_count], filters)
    formatted_payload(
      filters: filters,
      total_count: result[:total_count],
      returned_count: result[:returned_count],
      has_more: result[:has_more],
      next_offset: result[:next_offset],
      page_status: result[:resources].empty? && result[:total_count].positive? ? 'offset_out_of_range' : 'returned',
      search_status: status,
      link_status: link_status(status, filters[:service_id]),
      resources: result[:resources]
    )
  end

  def search_status(total_count, filters)
    return 'candidates' if total_count.positive?
    return 'no_recorded_link' if filters[:service_id].present? && filters[:query].blank?
    return 'no_match_with_recorded_link_filter' if filters[:service_id].present?
    return 'catalog_empty' if filters[:query].blank?

    'no_name_or_specialty_match'
  end

  def link_status(status, service_id)
    return 'not_checked' if service_id.blank?
    return 'no_recorded_link' if status == 'no_recorded_link'

    'price_link_unverified'
  end
end
