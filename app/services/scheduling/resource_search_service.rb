class Scheduling::ResourceSearchService
  MAX_LIMIT = 50
  MAX_OFFSET = 1_000_000_000

  def initialize(account:, query: nil, search_by: 'all', include_inactive: false, service_id: nil, limit: nil, offset: 0)
    @account = account
    @query = Scheduling::SearchText.normalize(query)
    @search_by = search_by.to_s.presence || 'all'
    @include_inactive = ActiveModel::Type::Boolean.new.cast(include_inactive)
    @service_id = Scheduling::IntegerNumericNormalizer.optional_positive_id(service_id)
    @limit = normalize_limit(limit)
    @offset = normalize_offset(offset)
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
         .merge(Scheduling::ServicePrice.active.where(account_id: @account.id, service_id: @service_id))
         .distinct
  end

  # Every query word must appear in the name (and specialty, for the "all" mode) in any order;
  # a hyphen or punctuation splits the query into separate words.
  def filter_by_query(scope)
    return scope if @query.blank?

    text_sql = Scheduling::SearchText.fold_sql(searched_columns_sql)
    tokens = Scheduling::SearchText.tokens(@query).presence || [@query]
    patterns = tokens.map { |token| "%#{ActiveRecord::Base.sanitize_sql_like(token)}%" }
    scope.where(patterns.map { "#{text_sql} ILIKE ?" }.join(' AND '), *patterns)
  end

  def searched_columns_sql
    case @search_by
    when 'name' then 'scheduling_resources.name'
    when 'specialty' then 'scheduling_resources.specialty'
    else "CONCAT_WS(' ', scheduling_resources.name, scheduling_resources.specialty)"
    end
  end

  def normalize_limit(value)
    numeric = value.to_i
    return MAX_LIMIT if numeric <= 0

    [numeric, MAX_LIMIT].min
  end

  def normalize_offset(value)
    numeric = value.to_i
    return 0 if numeric.negative?

    [numeric, MAX_OFFSET].min
  end
end
