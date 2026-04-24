class Captain::Tools::Copilot::SearchSchedulingServicesService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'search_scheduling_services'
  end

  description 'Search scheduling services by name, category, or direction'
  param :query, type: :string, desc: 'Service name, category, or direction query', required: false
  param :include_inactive, type: :boolean, desc: 'Whether to include inactive services', required: false
  param :limit, type: :number, desc: 'Maximum number of services to return', required: false

  def execute(query: nil, include_inactive: false, limit: nil)
    services = account.scheduling_services
    include_inactive = cast_boolean(include_inactive)
    services = services.active unless include_inactive
    if query.present?
      services = services.where(
        'LOWER(name) ILIKE :query OR LOWER(category) ILIKE :query OR LOWER(direction) ILIKE :query',
        query: "%#{query.to_s.downcase}%"
      )
    end

    total_count = services.count
    records = services.ordered.limit(parse_limit(limit)).map { |service| Scheduling::PayloadBuilder.service(service) }

    formatted_payload(
      filters: {
        query: query,
        include_inactive: include_inactive
      },
      total_count: total_count,
      services: records
    )
  end

  def active?
    @user.present? && assistant.account.feature_enabled?('scheduling')
  end
end
