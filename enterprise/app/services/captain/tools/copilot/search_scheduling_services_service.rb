class Captain::Tools::Copilot::SearchSchedulingServicesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_scheduling_services'
  end

  description 'Find catalog service candidates by text (word forms, aliases, category, direction), best name matches first; ' \
              'a text match does not confirm clinical eligibility or a MedElement route; page through results with offset'
  param :query, type: :string, desc: 'Service name, category, or direction query', required: false
  param :include_inactive, type: :boolean, desc: 'Whether to include inactive services', required: false
  param :limit, type: :number, desc: 'Maximum number of services to return', required: false
  param :offset, type: :number, desc: 'Pagination offset from the ranked candidate list; pass next_offset of the previous answer',
                 required: false

  def execute(query: nil, include_inactive: false, limit: nil, offset: nil)
    offset = parse_offset(offset)
    include_inactive = cast_boolean(include_inactive)
    services, search = search_scope(query, include_inactive)
    page = result_page(services, offset, parse_limit(limit))
    formatted_search_payload(page, search, query: query, include_inactive: include_inactive, offset: offset)
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end

  private

  def search_scope(query, include_inactive)
    services = account.scheduling_services
    services = services.active unless include_inactive
    return [services.ordered, nil] if query.blank?

    search = Scheduling::ServiceSearch.new(scope: services, query: query)
    [search.call, search]
  end

  def result_page(services, offset, limit)
    total_count = services.count
    records = services.preload(:prices).offset(offset).limit(limit).map { |service| Scheduling::PayloadBuilder.service(service) }
    next_offset = offset + records.length
    has_more = next_offset < total_count
    { total_count: total_count, records: records, has_more: has_more, next_offset: has_more ? next_offset : nil,
      page_status: records.empty? && total_count.positive? ? 'offset_out_of_range' : 'returned' }
  end

  # no_match: nothing found; partial_candidates: only some query words matched; candidate: one clear match
  # (or exactly one exact name); ambiguous: several equally plausible matches.
  def match_status(search, total_count, exact_name_matches)
    return 'catalog_listing' if search.nil? || search.match_kind == 'listing'
    return 'no_match' if total_count.zero?
    return 'partial_candidates' if search.match_kind == 'partial'
    return 'candidate' if total_count == 1 || exact_name_matches == 1

    'ambiguous'
  end

  def formatted_search_payload(page, search, query:, include_inactive:, offset:)
    exact_name_matches = search&.exact_name_count.to_i
    status = match_status(search, page[:total_count], exact_name_matches)
    formatted_payload(
      filters: { query: query, include_inactive: include_inactive, offset: offset },
      total_count: page[:total_count],
      returned_count: page[:records].length,
      has_more: page[:has_more],
      next_offset: page[:next_offset],
      page_status: page[:page_status],
      match_status: status,
      ambiguous: %w[ambiguous partial_candidates].include?(status),
      exact_name_matches: exact_name_matches,
      eligibility_status: 'unverified',
      services: page[:records]
    )
  end
end
