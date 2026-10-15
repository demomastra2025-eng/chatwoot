class Captain::Tools::Copilot::SearchSchedulingResourcesService < Captain::Tools::Copilot::BaseAccountTool
  NAME_DIFFERS_INSTRUCTION = 'The name differs from the request. Choose the best match from the patient\'s words (first visit = ' \
                             'primary; a named doctor = that specialist) and use its exact name in your reply or booking. ' \
                             'Ask the patient only when two or more entries fit equally.'.freeze
  SAME_NAME_INSTRUCTION = 'Several resources have exactly this name. Ask the patient which one is meant.'.freeze
  SINGLE_MATCH_INSTRUCTION = 'Exactly one specialist or room matches; you may book it when the patient asked to book, and name ' \
                             'this exact specialist or room in your booking confirmation.'.freeze

  def self.name
    'search_scheduling_resources'
  end

  description 'Search scheduling resources (specialists and diagnostic rooms) by name words in any order or by stored specialty; ' \
              'a service_id filter uses recorded price links, which are not clinical proof; page through results with offset'
  param :query, type: :string,
                desc: 'Resource name or stored specialty query. Write a surname and a specialty as a staff list does, not in the ' \
                      'case of the customer\'s sentence: "Асланова", not "Аслановой"; "хирург", not "хирургу"',
                required: false
  param :search_by, type: :string, desc: 'Search mode: name, specialty, or all', required: false
  param :service_id, type: :number, desc: 'Optional service ID to filter recorded active price links (not clinical eligibility)', required: false
  param :include_inactive, type: :boolean, desc: 'Whether to include inactive resources', required: false
  param :limit, type: :number, desc: 'Maximum number of specialists to return', required: false
  param :offset, type: :number, desc: 'Pagination offset for matching resources; pass next_offset of the previous answer', required: false

  def execute(query: nil, search_by: 'all', service_id: nil, include_inactive: false, limit: nil, offset: nil) # rubocop:disable Metrics/ParameterLists
    service_id = verified_optional_record_id(service_id, scope: account.scheduling_services, field_name: 'service_id')
    offset = parse_offset(offset)
    scoped_resource_ids = assistant.booking_resource_ids.presence if agent_scope?
    parsed_limit = parse_limit(limit)
    search_params = {
      account: account,
      query: query,
      search_by: search_by,
      service_id: service_id,
      include_inactive: include_inactive,
      limit: parsed_limit,
      offset: offset,
      resource_ids: scoped_resource_ids
    }
    result = Scheduling::ResourceSearchService.new(**search_params).perform
    if agent_scope? && result[:total_count].zero? && query.to_s.strip.present?
      result, query = fallback_agent_search(result, search_params)
    end

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

  def fallback_agent_search(result, search_params)
    query = search_params[:query]
    if search_params[:service_id].present? && search_params[:resource_ids].present?
      fallback = Scheduling::ResourceSearchService.new(**search_params, query: nil, search_by: nil).perform
      return [fallback, nil] if fallback[:total_count].positive?
    end

    tokens = Scheduling::SearchText.tokens(query)
    if tokens.size > 1
      tokens.each do |token|
        fallback = Scheduling::ResourceSearchService.new(**search_params, query: token).perform
        return [fallback, token] if fallback[:total_count].positive?
      end
    end

    [result, query]
  end

  def formatted_search_payload(result, filters)
    sole = sole_match?(result, filters)
    status = search_status(result, filters, sole)
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
      resources: result[:resources]
    }
    # Staff and Copilot see how the service filter was applied and the ambiguous flag; the patient agent gets the search status and
    # the instruction only (the link label named no action and gave the model a reason to doubt the filter and to hand the
    # conversation over; the flag next to the instruction "choose the best match" told it to ask the patient to confirm a name).
    payload.delete(:ambiguous) if agent_scope?
    payload[:link_status] = link_status(status, filters[:service_id]) unless agent_scope?
    instruction = instruction_for(status, result, sole)
    payload[:instruction] = instruction if instruction
    formatted_payload(payload)
  end

  def search_status(result, filters, sole)
    total_count = result[:total_count]
    return matched_status(result, filters, sole) if total_count.positive?
    return 'no_recorded_link' if filters[:service_id].present? && filters[:query].blank?
    return 'no_match_with_recorded_link_filter' if filters[:service_id].present?
    return 'catalog_empty' if filters[:query].blank?

    'no_name_or_specialty_match'
  end

  # Every text match holds all words of the request. candidate: the one active resource that matched (sole), or exactly one
  # resource whose name has exactly the words of the request among several; ambiguous: every other text match.
  def matched_status(result, filters, sole)
    return 'candidates' if filters[:query].blank?
    return 'candidate' if sole || (result[:exact_name_matches] == 1 && !result[:exact_name_truncated])

    'ambiguous'
  end

  # The only active resource that matched is a confident candidate even when its name is longer than the request: the
  # customer is told its exact name in the booking confirmation. The search finds a word anywhere inside a name, so every word
  # of the request must also stand as a whole word of the name (and of the specialty unless only names were searched),
  # numbers in the same order: "Асланов" is not "Асланова", and "Кабинет 2" is not "Кабинет 12".
  def sole_match?(result, filters)
    row = result[:resources].first
    return false unless filters[:query].present? && result[:total_count] == 1 && row && row[:active] == true
    return false if Scheduling::SearchText.truncated?(filters[:query])

    text = [row[:name], (row[:specialty] unless filters[:search_by] == 'name')].compact_blank.join(' ')
    Scheduling::SearchText.request_covered?(Scheduling::SearchText.normalize(filters[:query]),
                                            [Scheduling::SearchText.normalize(text, max_length: nil)])
  end

  def instruction_for(status, result, sole)
    return SINGLE_MATCH_INSTRUCTION if status == 'candidate' && sole
    return unless status == 'ambiguous'

    result[:exact_name_matches].to_i > 1 ? SAME_NAME_INSTRUCTION : NAME_DIFFERS_INSTRUCTION
  end

  def link_status(status, service_id)
    return 'not_checked' if service_id.blank?
    return 'no_recorded_link' if status == 'no_recorded_link'

    'price_link_unverified'
  end
end
