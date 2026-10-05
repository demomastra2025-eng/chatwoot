class Captain::Tools::Copilot::SearchSchedulingServicesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_scheduling_services'
  end

  description 'Find catalog service candidates by text; a match does not confirm clinical eligibility or a MedElement route'
  param :query, type: :string, desc: 'Service name, category, or direction query', required: false
  param :include_inactive, type: :boolean, desc: 'Whether to include inactive services', required: false
  param :limit, type: :number, desc: 'Maximum number of services to return', required: false
  param :offset, type: :number, desc: 'Pagination offset from the ranked candidate list', required: false

  def execute(query: nil, include_inactive: false, limit: nil, offset: nil)
    offset = parse_offset(offset)
    include_inactive = cast_boolean(include_inactive)
    services = search_scope(query, include_inactive)
    page = result_page(services, offset, parse_limit(limit))
    formatted_search_payload(page, query: query, include_inactive: include_inactive, offset: offset)
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
    return services.ordered if query.blank?

    @search = Scheduling::ServiceSearch.new(scope: services, query: query)
    @search.call
  end

  def result_page(services, offset, limit)
    total_count = services.count
    records = services.offset(offset).limit(limit).map { |service| Scheduling::PayloadBuilder.service(service) }
    next_offset = offset + records.length
    has_more = next_offset < total_count
    { total_count: total_count, records: records, has_more: has_more, next_offset: has_more ? next_offset : nil,
      page_status: records.empty? && total_count.positive? ? 'offset_out_of_range' : 'returned' }
  end

  def match_status(query, total_count)
    return 'catalog_listing' if query.blank?
    return 'no_match' if total_count.zero?
    return 'partial_candidates' if @search.match_kind == 'partial'

    total_count > 1 ? 'ambiguous' : 'candidate'
  end

  def formatted_search_payload(page, query:, include_inactive:, offset:)
    formatted_payload(
      filters: { query: query, include_inactive: include_inactive, offset: offset },
      total_count: page[:total_count],
      returned_count: page[:records].length,
      has_more: page[:has_more],
      next_offset: page[:next_offset],
      page_status: page[:page_status],
      match_status: match_status(query, page[:total_count]),
      ambiguous: page[:total_count] > 1,
      eligibility_status: 'unverified',
      services: page[:records]
    )
  end
end
