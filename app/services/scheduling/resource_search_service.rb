class Scheduling::ResourceSearchService
  MAX_LIMIT = 50

  def initialize(account:, query: nil, search_by: 'all', include_inactive: false, service_id: nil, limit: nil)
    @account = account
    @query = query.to_s.strip
    @search_by = search_by.to_s.presence || 'all'
    @include_inactive = ActiveModel::Type::Boolean.new.cast(include_inactive)
    @service_id = Scheduling::IntegerNumericNormalizer.optional_positive_id(service_id)
    @limit = normalize_limit(limit)
  end

  def perform
    scope = @account.scheduling_resources.not_deleted_from_scheduling
    scope = scope.active unless @include_inactive
    scope = filter_by_service(scope)
    scope = filter_by_query(scope)
    scope = scope.ordered

    {
      total_count: scope.count,
      resources: scope.limit(@limit).map { |resource| Scheduling::PayloadBuilder.resource(resource) }
    }
  end

  private

  def filter_by_service(scope)
    return scope unless @service_id.present?

    scope.joins(:service_prices)
         .merge(Scheduling::ServicePrice.active.where(service_id: @service_id))
         .distinct
  end

  def filter_by_query(scope)
    return scope if @query.blank?

    search_pattern = "%#{ActiveRecord::Base.sanitize_sql_like(@query.downcase)}%"
    case @search_by
    when 'name'
      scope.where('LOWER(scheduling_resources.name) ILIKE ?', search_pattern)
    when 'specialty'
      scope.where('LOWER(scheduling_resources.specialty) ILIKE ?', search_pattern)
    else
      scope.where(
        'LOWER(scheduling_resources.name) ILIKE :query OR LOWER(scheduling_resources.specialty) ILIKE :query',
        query: search_pattern
      )
    end
  end

  def normalize_limit(value)
    numeric = value.to_i
    return MAX_LIMIT if numeric <= 0

    [numeric, MAX_LIMIT].min
  end
end
