class Captain::Tools::Copilot::SearchSchedulingResourcesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_scheduling_resources'
  end

  description 'Search scheduling specialists by name or specialty, with optional service filtering'
  param :query, type: :string, desc: 'Resource name or specialty query', required: false
  param :search_by, type: :string, desc: 'Search mode: name, specialty, or all', required: false
  param :service_id, type: :number, desc: 'Optional service ID to keep only specialists who can perform it', required: false
  param :include_inactive, type: :boolean, desc: 'Whether to include inactive resources', required: false
  param :limit, type: :number, desc: 'Maximum number of specialists to return', required: false

  def execute(query: nil, search_by: 'all', service_id: nil, include_inactive: false, limit: nil)
    service_id = verified_optional_record_id(service_id, scope: account.scheduling_services, field_name: 'service_id')
    result = Scheduling::ResourceSearchService.new(
      account: account,
      query: query,
      search_by: search_by,
      service_id: service_id,
      include_inactive: include_inactive,
      limit: parse_limit(limit)
    ).perform

    formatted_search_payload(result: result, query: query, search_by: search_by, service_id: service_id, include_inactive: include_inactive)
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end

  private

  def formatted_search_payload(result:, query:, search_by:, service_id:, include_inactive:)
    formatted_payload(
      filters: {
        query: query.to_s.presence,
        search_by: search_by.to_s.presence || 'all',
        service_id: service_id,
        include_inactive: cast_boolean(include_inactive)
      }.compact,
      total_count: result[:total_count],
      resources: result[:resources]
    )
  end
end
