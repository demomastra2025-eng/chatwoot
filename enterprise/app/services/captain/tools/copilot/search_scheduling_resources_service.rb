class Captain::Tools::Copilot::SearchSchedulingResourcesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_scheduling_resources'
  end

  description 'Search scheduling specialists by name or specialty'
  param :query, type: :string, desc: 'Resource name or specialty query', required: false
  param :include_inactive, type: :boolean, desc: 'Whether to include inactive resources', required: false

  def execute(query: nil, include_inactive: false)
    resources = account.scheduling_resources.not_deleted_from_scheduling
    resources = resources.active unless cast_boolean(include_inactive)
    if query.present?
      resources = resources.where('LOWER(name) ILIKE :query OR LOWER(specialty) ILIKE :query', query: "%#{query.to_s.downcase}%")
    end

    formatted_payload(resources.ordered.limit(MAX_RESULTS).map { |resource| Scheduling::PayloadBuilder.resource(resource) })
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end
end
