class Captain::Tools::Copilot::SearchSchedulingServicesService < Captain::Tools::Copilot::BaseAccountTool
  NAME_DIFFERS_INSTRUCTION = 'The service name differs from the request. Tell the patient the exact name of the service and ask ' \
                             'to confirm it; never book on a non-exact name.'.freeze
  SAME_NAME_INSTRUCTION = 'Several services have exactly this name. Ask the patient which one is meant (category, direction); ' \
                          'never book on a guess.'.freeze
  SINGLE_MATCH_INSTRUCTION = 'Exactly one service matches; you may book it when the customer asked to book, and name this ' \
                             'exact service in your booking confirmation.'.freeze
  PAGING_INSTRUCTION = 'Further pages are not reachable in this run. Refine the query with more words of the exact service ' \
                       'name instead of paging.'.freeze

  def self.name
    'search_scheduling_services'
  end

  description 'Find catalog service candidates by text (word forms, aliases, category, direction), best name matches first; ' \
              'a text match does not confirm clinical eligibility or a MedElement route; page through results with offset'
  param :query, type: :string,
                desc: 'Service name, category, or direction query. Write the words as a catalog title does, not in the case of the ' \
                      'customer\'s sentence: "консультация терапевта", not "консультацию терапевта"',
                required: false
  param :include_inactive, type: :boolean, desc: 'Whether to include inactive services', required: false
  param :limit, type: :number, desc: 'Maximum number of services to return', required: false
  param :offset, type: :number, desc: 'Pagination offset from the ranked candidate list; pass next_offset of the previous answer',
                 required: false

  def execute(query: nil, include_inactive: false, limit: nil, offset: nil)
    offset = parse_offset(offset)
    include_inactive = cast_boolean(include_inactive)
    limit = parse_limit(limit)
    services, search = search_scope(query, include_inactive)
    page = result_page(services, offset, limit)
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
    page_services = services.offset(offset).limit(limit).to_a
    prices_by_service = price_rows_by_service(page_services)
    records = page_services.map { |service| service_payload(service, prices_by_service.fetch(service.id, [])) }
    next_offset = offset + records.length
    has_more = next_offset < total_count
    reachable = has_more && page_reachable?(next_offset, limit)
    { total_count: total_count, records: records, has_more: has_more, next_offset: reachable ? next_offset : nil,
      first_service: page_services.first, paging_unreachable: has_more && !reachable,
      page_status: records.empty? && total_count.positive? ? 'offset_out_of_range' : 'returned' }
  end

  # A price row is a recorded link between a service and a resource, never proof that the resource may perform the
  # service. Only the active rows of the service's own account are listed, each one labelled as unverified.
  def service_payload(service, prices)
    Scheduling::PayloadBuilder.service(service, prices: []).merge(prices: prices)
  end

  def price_rows_by_service(services)
    return {} if services.empty?

    Scheduling::ServicePrice.active.joins(:resource)
                            .where(account_id: account.id, service_id: services.map(&:id))
                            .where(scheduling_resources: { account_id: account.id, active: true })
                            .order(:id).group_by(&:service_id).transform_values do |prices|
      prices.map do |price|
        Scheduling::PayloadBuilder.service_price(price).merge(service_eligibility_status: 'price_link_unverified')
      end
    end
  end

  # The loop guard lets one run call this tool a fixed number of times. A next_offset that needs a call beyond that budget
  # would only be refused, so it is not offered.
  def page_reachable?(next_offset, limit)
    (next_offset / limit) < Captain::Runtime::ToolLoopGuard::MAX_REQUESTS_BY_TOOL.fetch(self.class.name)
  end

  # no_match: nothing found; partial_candidates: only some query words matched; candidate: the one active service that
  # matched all words of the request (see sole_match?), or exactly one service whose name (or alias) has exactly the words
  # of the request among several; ambiguous: everything else that matched all words.
  def match_status(search, page, exact_name_matches)
    return 'catalog_listing' if search.nil? || search.match_kind == 'listing'
    return 'no_match' if page[:total_count].zero?
    return 'partial_candidates' if search.match_kind == 'partial'
    return 'candidate' if sole_match?(page, search) || exact_name_candidate?(search, exact_name_matches)

    'ambiguous'
  end

  def exact_name_candidate?(search, exact_name_matches)
    exact_name_matches == 1 && !search.exact_name_truncated?
  end

  # The only active service that matched all words of the request is a confident candidate even when its name is longer
  # than the request: the customer is told its exact name in the booking confirmation. The search stems words and ignores
  # short ones, so the name must also hold every word of the request as written, qualifiers and numbers in the same order:
  # "с контрастом" is not "без контраста", "кисти" is not "кисты".
  def sole_match?(page, search)
    service = page[:first_service]
    return false unless page[:total_count] == 1 && service&.active? && search.match_kind == 'all_concepts'

    search.request_covered_by?(service)
  end

  def confirmation_needed?(status)
    %w[ambiguous partial_candidates].include?(status)
  end

  def instruction_for(status, exact_name_matches, page, search)
    return SINGLE_MATCH_INSTRUCTION if status == 'candidate' && sole_match?(page, search)
    return unless confirmation_needed?(status)

    exact_name_matches > 1 ? SAME_NAME_INSTRUCTION : NAME_DIFFERS_INSTRUCTION
  end

  def formatted_search_payload(page, search, query:, include_inactive:, offset:)
    exact_name_matches = search&.exact_name_count.to_i
    status = match_status(search, page, exact_name_matches)
    payload = {
      filters: { query: query, include_inactive: include_inactive, offset: offset },
      total_count: page[:total_count],
      returned_count: page[:records].length,
      has_more: page[:has_more],
      next_offset: page[:next_offset],
      page_status: page[:page_status],
      match_status: status,
      ambiguous: confirmation_needed?(status),
      exact_name_matches: exact_name_matches,
      eligibility_status: 'unverified',
      services: page[:records]
    }
    instruction = instruction_for(status, exact_name_matches, page, search)
    payload[:instruction] = instruction if instruction
    payload[:paging_instruction] = PAGING_INSTRUCTION if page[:paging_unreachable]
    formatted_payload(payload)
  end
end
