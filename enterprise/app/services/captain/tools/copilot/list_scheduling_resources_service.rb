class Captain::Tools::Copilot::ListSchedulingResourcesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'list_scheduling_resources'
  end

  description 'List scheduling specialists, with optional filters for service and activity state'
  param :service_id, type: :number, desc: 'Optional service ID to keep only specialists who can perform it', required: false
  param :include_inactive, type: :boolean, desc: 'Whether to include inactive resources', required: false
  param :limit, type: :number, desc: 'Maximum number of specialists to return', required: false

  def execute(service_id: nil, include_inactive: false, limit: nil)
    result = Scheduling::ResourceSearchService.new(
      account: account,
      service_id: service_id,
      include_inactive: include_inactive,
      limit: parse_limit(limit)
    ).perform

    formatted_payload(
      service_id: service_id,
      include_inactive: cast_boolean(include_inactive),
      total_count: result[:total_count],
      resources: result[:resources]
    )
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end
end
