class Scheduling::ResourceSearchService
  MAX_LIMIT = 50
  MAX_OFFSET = 1_000_000_000
  # The equal-name test reads at most this many rows; it only bounds the work, never the words that are compared.
  EXACT_CANDIDATE_LIMIT = 500

  def initialize(account:, query: nil, search_by: 'all', include_inactive: false, service_id: nil, limit: nil, offset: 0) # rubocop:disable Metrics/ParameterLists
    @account = account
    @query = Scheduling::SearchText.normalize(query)
    @query_truncated = Scheduling::SearchText.truncated?(query)
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

    total_count = scope.count
    equal = equal_name_rows(scope)
    resources = equal_first(scope, equal[:ids]).offset(@offset).limit(@limit).map { |resource| resource_row(resource, equal[:ids]) }
    next_offset = @offset + resources.length
    has_more = next_offset < total_count

    { total_count: total_count, resources: resources, returned_count: resources.length, offset: @offset,
      has_more: has_more, next_offset: has_more ? next_offset : nil,
      exact_name_matches: equal[:ids].size, exact_name_truncated: equal[:truncated] }
  end

  private

  def filter_by_service(scope)
    return scope if @service_id.blank?

    scope.where(id: Scheduling::ServicePrice.active.where(account_id: @account.id, service_id: @service_id).select(:resource_id))
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

  # The resources whose name, or stored specialty, has exactly the words of the query (any order, every word counts, no
  # word forms: Асланов and Асланова are two names; a name with a number is read in order). Only such a resource may be
  # presented as the one confident match; a part of a name or a longer specialty is not an equal name.
  def equal_name_rows(scope)
    return { ids: [], truncated: false } if @query.blank? || @query_truncated

    rows = scope.reorder(:id).limit(EXACT_CANDIDATE_LIMIT + 1).pluck(:id, :name, :specialty)
    ids = rows.first(EXACT_CANDIDATE_LIMIT).filter_map { |id, name, specialty| id if equal_text?(name, specialty) }
    { ids: ids, truncated: rows.size > EXACT_CANDIDATE_LIMIT }
  end

  def equal_text?(name, specialty)
    texts = case @search_by
            when 'name' then [name]
            when 'specialty' then [specialty]
            else [name, specialty]
            end
    texts.compact_blank.any? do |text|
      Scheduling::SearchText.same_words?(@query, Scheduling::SearchText.normalize(text, max_length: nil), stemmed: false)
    end
  end

  # The equal resource is listed before the longer or partial names, so that the confident match is the first row of
  # the answer whatever the alphabetical order is; the rest keeps the name order.
  def equal_first(scope, equal_ids)
    return scope.ordered if equal_ids.empty?

    equal_rank = Arel::Nodes::Case.new.when(Scheduling::Resource.arel_table[:id].in(equal_ids)).then(0).else(1)
    scope.order(equal_rank.asc, :name, :id)
  end

  def resource_row(resource, equal_ids)
    row = Scheduling::PayloadBuilder.resource(resource)
    row[:exact_name_match] = true if equal_ids.include?(resource.id)
    row
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
