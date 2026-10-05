class Scheduling::ResourceSearchService
  MAX_LIMIT = 50
  MAX_QUERY_TOKENS = 8

  def initialize(account:, query: nil, search_by: 'all', include_inactive: false, service_id: nil, limit: nil, offset: 0)
    @account = account
    @query = query.to_s.strip
    @search_by = search_by.to_s.presence || 'all'
    @include_inactive = ActiveModel::Type::Boolean.new.cast(include_inactive)
    @service_id = Scheduling::IntegerNumericNormalizer.optional_positive_id(service_id)
    @limit = normalize_limit(limit)
    @offset = offset
  end

  def perform
    scope = @account.scheduling_resources.not_deleted_from_scheduling
    scope = scope.active unless @include_inactive
    scope = filter_by_service(scope)
    scope = filter_by_query(scope)
    scope = scope.ordered

    total_count = scope.count
    resources = scope.offset(@offset).limit(@limit).map { |resource| Scheduling::PayloadBuilder.resource(resource) }
    next_offset = @offset + resources.length
    has_more = next_offset < total_count

    { total_count: total_count, resources: resources, returned_count: resources.length, offset: @offset,
      has_more: has_more, next_offset: has_more ? next_offset : nil }
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

    text_sql = case @search_by
               when 'name' then 'LOWER(scheduling_resources.name)'
               when 'specialty' then 'LOWER(scheduling_resources.specialty)'
               else "LOWER(CONCAT_WS(' ', scheduling_resources.name, scheduling_resources.specialty))"
               end
    tokens = @query.downcase.scan(/[[:alnum:]]+/).first(MAX_QUERY_TOKENS)
    tokens = [@query.downcase] if tokens.blank?
    patterns = tokens.map { |token| "%#{ActiveRecord::Base.sanitize_sql_like(token)}%" }
    scope.where(patterns.map { "#{text_sql} ILIKE ?" }.join(' AND '), *patterns)
  end

  def normalize_limit(value)
    numeric = value.to_i
    return MAX_LIMIT if numeric <= 0

    [numeric, MAX_LIMIT].min
  end
end
