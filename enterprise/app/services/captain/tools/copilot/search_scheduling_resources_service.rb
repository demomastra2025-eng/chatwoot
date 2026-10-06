class Captain::Tools::Copilot::SearchSchedulingResourcesService < Captain::Tools::Copilot::BaseAccountTool
  NAME_DIFFERS_INSTRUCTION = 'The resource name differs from the request. Tell the patient the exact name of the specialist or room ' \
                             'and ask to confirm it; never book on a non-exact name.'.freeze
  SAME_NAME_INSTRUCTION = 'Several resources have exactly this name. Ask the patient which one is meant; never book on a guess.'.freeze

  def self.name
    'search_scheduling_resources'
  end

  description 'Search scheduling resources (specialists and diagnostic rooms) by name words in any order or by stored specialty; ' \
              'a service_id filter uses recorded price links, which are not clinical proof; page through results with offset'
  param :query, type: :string, desc: 'Resource name or stored specialty query', required: false
  param :search_by, type: :string, desc: 'Search mode: name, specialty, or all', required: false
  param :service_id, type: :number, desc: 'Optional service ID to filter recorded active price links (not clinical eligibility)', required: false
  param :include_inactive, type: :boolean, desc: 'Whether to include inactive resources', required: false
  param :limit, type: :number, desc: 'Maximum number of specialists to return', required: false
  param :offset, type: :number, desc: 'Pagination offset for matching resources; pass next_offset of the previous answer', required: false

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
    status = search_status(result, filters)
    payload = {
      filters: filters,
      total_count: result[:total_count],
      returned_count: result[:returned_count],
      has_more: result[:has_more],
      next_offset: result[:next_offset],
      page_status: result[:resources].empty? && result[:total_count].positive? ? 'offset_out_of_range' : 'returned',
      search_status: status,
      ambiguous: status == 'ambiguous',
      exact_name_matches: result[:exact_name_matches].to_i,
      link_status: link_status(status, filters[:service_id]),
      resources: result[:resources]
    }
    payload[:instruction] = instruction_for(result) if status == 'ambiguous'
    formatted_payload(payload)
  end

  def search_status(result, filters)
    total_count = result[:total_count]
    return matched_status(result, filters) if total_count.positive?
    return 'no_recorded_link' if filters[:service_id].present? && filters[:query].blank?
    return 'no_match_with_recorded_link_filter' if filters[:service_id].present?
    return 'catalog_empty' if filters[:query].blank?

    'no_name_or_specialty_match'
  end

  # candidate: exactly one resource whose name has exactly the words of the request; ambiguous: every other text match.
  def matched_status(result, filters)
    return 'candidates' if filters[:query].blank?

    result[:exact_name_matches] == 1 && !result[:exact_name_truncated] ? 'candidate' : 'ambiguous'
  end

  def instruction_for(result)
    result[:exact_name_matches].to_i > 1 ? SAME_NAME_INSTRUCTION : NAME_DIFFERS_INSTRUCTION
  end

  def link_status(status, service_id)
    return 'not_checked' if service_id.blank?
    return 'no_recorded_link' if status == 'no_recorded_link'

    'price_link_unverified'
  end
end
