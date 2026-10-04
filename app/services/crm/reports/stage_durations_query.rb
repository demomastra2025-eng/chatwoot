class Crm::Reports::StageDurationsQuery < Crm::Reports::StageVisitsQuery
  QUERY_KIND = 'stage_durations'.freeze
  FILTER_KEYS = %i[pipeline_id stage_id].freeze
  FILTER_COLUMNS = { pipeline_id: 'pipeline_id', stage_id: 'stage_id' }.freeze
  GROUP_COLUMNS = %w[pipeline_id pipeline_name stage_id stage_name stage_outcome].freeze
  def aggregate_rows
    relation.group(*GROUP_COLUMNS).pluck(
      *GROUP_COLUMNS,
      Arel.sql('COUNT(*)'),
      Arel.sql("COUNT(*) FILTER (WHERE reliability = 'exact')"),
      Arel.sql("COUNT(*) FILTER (WHERE reliability = 'estimated')"),
      Arel.sql("COUNT(*) FILTER (WHERE coverage = 'unknown_before')"),
      Arel.sql('MIN(reliable_since)'),
      sql_fragments.percentile_sql(0.5),
      sql_fragments.percentile_sql(0.75),
      sql_fragments.percentile_sql(0.5, reliability: 'exact'),
      sql_fragments.percentile_sql(0.75, reliability: 'exact'),
      sql_fragments.percentile_sql(0.5, reliability: 'estimated'),
      sql_fragments.percentile_sql(0.75, reliability: 'estimated'),
      *sql_fragments.histogram_sql
    ).map { |values| aggregate_payload(values) }
  end

  def drill_down_rows
    paginated_relation(relation, order: { exited_at: :desc, id: :desc }).map { |visit| drill_down_payload(visit) }
  end

  def total_count
    relation.count
  end

  def meta
    earliest_reliable_since = relation.minimum(:reliable_since)
    base_meta(
      reliable_since: earliest_reliable_since,
      coverage: overall_coverage(earliest_reliable_since)
    ).merge(
      window_fact: 'exited_at',
      ongoing_excluded_count: ongoing_excluded_count,
      negative_interval_excluded_count: negative_interval_excluded_count
    )
  end

  def pagination_meta
    meta.merge(page: page, per_page: per_page, total_count: total_count)
  end

  def relation
    @relation ||= Crm::StageVisit.unscoped.from("(#{filtered_sql}) crm_stage_visits")
  end

  private

  def sql_fragments
    @sql_fragments ||= ::Crm::Reports::StageDurationSqlFragments.new(connection: connection)
  end

  def filtered_sql # rubocop:disable Metrics/MethodLength
    <<~SQL.squish
      SELECT
        visits.id,
        visits.deal_id,
        visits.pipeline_id,
        visits.pipeline_name,
        visits.stage_id,
        visits.stage_name,
        visits.stage_outcome,
        visits.entered_at,
        visits.exited_at,
        visits.reliable_since,
        EXTRACT(EPOCH FROM (visits.exited_at - visits.entered_at))::bigint AS duration_seconds,
        CASE WHEN visits.estimated THEN 'estimated' ELSE 'exact' END AS reliability,
        CASE
          WHEN visits.entered_at < visits.reliable_since THEN 'unknown_before'
          WHEN visits.estimated THEN 'estimated'
          ELSE 'exact'
        END AS coverage
      FROM crm_stage_visits visits
      INNER JOIN (#{visible_deals_sql}) visible_deals ON visible_deals.id = visits.deal_id
      WHERE visits.account_id = #{connection.quote(account.id)}
        AND visits.exited_at IS NOT NULL
        AND visits.exited_at >= visits.entered_at
        AND visits.exited_at >= #{connection.quote(from_time.utc)}
        AND visits.exited_at < #{connection.quote(to_time.utc)}
        #{filter_sql_suffix}
    SQL
  end

  def filter_sql_suffix
    predicates = filter_predicates
    predicates.empty? ? '' : "AND #{predicates.join(' AND ')}"
  end

  def aggregate_payload(values)
    dimensions = GROUP_COLUMNS.zip(values.shift(GROUP_COLUMNS.length)).to_h.symbolize_keys
    total_count, exact_count, estimated_count, unknown_count, reliable_since = values.shift(5)
    median, p75, exact_median, exact_p75, estimated_median, estimated_p75 = values.shift(6)

    dimensions.merge(
      total_count: total_count.to_i,
      exact_count: exact_count.to_i,
      estimated_count: estimated_count.to_i,
      median_duration_seconds: duration_number(median),
      p75_duration_seconds: duration_number(p75),
      exact_duration_seconds: duration_summary(exact_count, exact_median, exact_p75),
      estimated_duration_seconds: duration_summary(estimated_count, estimated_median, estimated_p75),
      histogram: histogram_payload(values),
      reliable_since: reliable_since.utc.iso8601(6),
      coverage: aggregate_coverage(unknown_count.to_i, estimated_count.to_i, reliable_since)
    )
  end

  def duration_summary(count, median, p75)
    {
      count: count.to_i,
      median: duration_number(median),
      p75: duration_number(p75)
    }
  end

  def duration_number(value)
    value&.to_f&.round(3)
  end

  def histogram_payload(counts)
    sql_fragments.histogram_payload(counts)
  end

  def aggregate_coverage(unknown_count, estimated_count, reliable_since)
    return 'unknown_before' if unknown_count.positive? || from_time < reliable_since
    return 'estimated' if estimated_count.positive?

    'exact'
  end

  def overall_coverage(earliest_reliable_since)
    return 'unknown_before' if earliest_reliable_since.blank? || from_time < earliest_reliable_since
    return 'unknown_before' if relation.exists?(coverage: 'unknown_before')
    return 'estimated' if relation.exists?(reliability: 'estimated')

    'exact'
  end

  def drill_down_payload(visit)
    {
      stage_visit_id: visit.id,
      deal_id: visit.deal_id,
      stage: {
        pipeline_id: visit.pipeline_id,
        pipeline_name: visit.pipeline_name,
        stage_id: visit.stage_id,
        stage_name: visit.stage_name,
        stage_outcome: visit.stage_outcome
      },
      entered_at: visit.entered_at.utc.iso8601(6),
      exited_at: visit.exited_at.utc.iso8601(6),
      duration_seconds: visit.duration_seconds.to_i,
      reliability: visit.reliability,
      reliable_since: visit.reliable_since.utc.iso8601(6),
      coverage: visit.coverage
    }
  end

  def ongoing_excluded_count
    excluded_relation.where(exited_at: nil).where('entered_at < ?', to_time.utc).count
  end

  def negative_interval_excluded_count
    excluded_relation.where.not(exited_at: nil)
                     .where(exited_at: from_time.utc...to_time.utc)
                     .where('exited_at < entered_at').count
  end

  def excluded_relation
    scope = Crm::StageVisit.unscoped.joins("INNER JOIN (#{visible_deals_sql}) visible_deals ON visible_deals.id = crm_stage_visits.deal_id")
                           .where(account_id: account.id)
    filters.reduce(scope) { |relation_scope, (key, value)| relation_scope.where(FILTER_COLUMNS.fetch(key) => value) }
  end
end
