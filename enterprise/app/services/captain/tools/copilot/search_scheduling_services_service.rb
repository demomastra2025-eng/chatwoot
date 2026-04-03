class Captain::Tools::Copilot::SearchSchedulingServicesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_scheduling_services'
  end

  description 'Search scheduling services by name, category, or direction'
  param :query, type: :string, desc: 'Service name, category, or direction query', required: false
  param :include_inactive, type: :boolean, desc: 'Whether to include inactive services', required: false

  def execute(query: nil, include_inactive: false)
    services = account.scheduling_services
    services = services.active unless cast_boolean(include_inactive)
    if query.present?
      services = services.where(
        'LOWER(name) ILIKE :query OR LOWER(category) ILIKE :query OR LOWER(direction) ILIKE :query',
        query: "%#{query.to_s.downcase}%"
      )
    end

    formatted_payload(services.ordered.limit(MAX_RESULTS).map { |service| Scheduling::PayloadBuilder.service(service) })
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end
end
