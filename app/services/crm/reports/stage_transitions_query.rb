class Crm::Reports::StageTransitionsQuery < Crm::Reports::StageVisitsQuery
  QUERY_KIND = 'stage_transitions'.freeze
  FILTER_KEYS = %i[from_pipeline_id from_stage_id pipeline_id stage_id].freeze
  FILTER_COLUMNS = {
    from_pipeline_id: 'from_pipeline_id',
    from_stage_id: 'from_stage_id',
    pipeline_id: 'to_pipeline_id',
    stage_id: 'to_stage_id'
  }.freeze
  GROUP_COLUMNS = %w[
    from_pipeline_id from_pipeline_name from_stage_id from_stage_name from_stage_outcome
    to_pipeline_id to_pipeline_name to_stage_id to_stage_name to_stage_outcome
  ].freeze

  def aggregate_rows
    relation.group(*GROUP_COLUMNS).pluck(
      *GROUP_COLUMNS,
      Arel.sql('COUNT(*)'),
      Arel.sql("COUNT(*) FILTER (WHERE reliability = 'exact')"),
      Arel.sql("COUNT(*) FILTER (WHERE reliability = 'estimated')"),
      Arel.sql("COUNT(*) FILTER (WHERE coverage = 'unknown_before')"),
      Arel.sql('MIN(transition_reliable_since)')
    ).map { |values| aggregate_payload(values) }
  end

  def drill_down_rows
    paginated_relation(relation, order: { entered_at: :desc, id: :desc }).map { |transition| drill_down_payload(transition) }
  end

  def total_count
    relation.count
  end

  def meta
    earliest_reliable_since = relation.minimum(:transition_reliable_since)
    base_meta(
      reliable_since: earliest_reliable_since,
      coverage: overall_coverage(earliest_reliable_since)
    )
  end

  def pagination_meta
    meta.merge(page: page, per_page: per_page, total_count: total_count)
  end

  def relation
    @relation ||= Crm::StageVisit.unscoped.from("(#{filtered_sql}) crm_stage_visits")
  end

  private

  def filtered_sql # rubocop:disable Metrics/MethodLength
    <<~SQL.squish
      WITH ordered_visits AS (
        SELECT
          visits.id AS transition_visit_id,
          visits.deal_id,
          visits.entered_at,
          visits.pipeline_id AS to_pipeline_id,
          visits.pipeline_name AS to_pipeline_name,
          visits.stage_id AS to_stage_id,
          visits.stage_name AS to_stage_name,
          visits.stage_outcome AS to_stage_outcome,
          visits.estimated AS to_estimated,
          visits.reliable_since AS to_reliable_since,
          LAG(visits.id) OVER visit_order AS previous_visit_id,
          LAG(visits.pipeline_id) OVER visit_order AS from_pipeline_id,
          LAG(visits.pipeline_name) OVER visit_order AS from_pipeline_name,
          LAG(visits.stage_id) OVER visit_order AS from_stage_id,
          LAG(visits.stage_name) OVER visit_order AS from_stage_name,
          LAG(visits.stage_outcome) OVER visit_order AS from_stage_outcome,
          LAG(visits.estimated) OVER visit_order AS from_estimated,
          LAG(visits.reliable_since) OVER visit_order AS from_reliable_since
        FROM crm_stage_visits visits
        INNER JOIN (#{visible_deals_sql}) visible_deals ON visible_deals.id = visits.deal_id
        WHERE visits.account_id = #{connection.quote(account.id)}
        WINDOW visit_order AS (PARTITION BY visits.deal_id ORDER BY visits.entered_at ASC, visits.id ASC)
      ), transitions AS (
        SELECT
          ordered_visits.*,
          GREATEST(from_reliable_since, to_reliable_since) AS transition_reliable_since
        FROM ordered_visits
        WHERE previous_visit_id IS NOT NULL
      )
      SELECT
        transitions.transition_visit_id AS id,
        transitions.*,
        CASE
          WHEN from_estimated OR to_estimated THEN 'estimated'
          ELSE 'exact'
        END AS reliability,
        CASE
          WHEN entered_at < transition_reliable_since THEN 'unknown_before'
          WHEN from_estimated OR to_estimated THEN 'estimated'
          ELSE 'exact'
        END AS coverage
      FROM transitions
      WHERE #{transition_filter_predicates.join(' AND ')}
    SQL
  end

  def transition_filter_predicates
    [
      "entered_at >= #{connection.quote(from_time.utc)}",
      "entered_at < #{connection.quote(to_time.utc)}",
      *filter_predicates
    ]
  end

  def aggregate_payload(values)
    dimensions = GROUP_COLUMNS.zip(values.shift(GROUP_COLUMNS.length)).to_h.symbolize_keys
    total_count, exact_count, estimated_count, unknown_count, reliable_since = values
    dimensions.merge(
      total_count: total_count.to_i,
      exact_count: exact_count.to_i,
      estimated_count: estimated_count.to_i,
      reliable_since: reliable_since.utc.iso8601(6),
      coverage: aggregate_coverage(unknown_count.to_i, estimated_count.to_i, reliable_since)
    )
  end

  def aggregate_coverage(unknown_count, estimated_count, reliable_since)
    return 'unknown_before' if unknown_count.positive? || from_time < reliable_since
    return 'estimated' if estimated_count.positive?

    'exact'
  end

  def drill_down_payload(transition)
    {
      transition_visit_id: transition.transition_visit_id,
      deal_id: transition.deal_id,
      entered_at: transition.entered_at.utc.iso8601(6),
      from: snapshot_payload(transition, :from),
      to: snapshot_payload(transition, :to),
      reliability: transition.reliability,
      reliable_since: transition.transition_reliable_since.utc.iso8601(6),
      coverage: transition.coverage
    }
  end

  def snapshot_payload(transition, direction)
    {
      pipeline_id: transition.public_send("#{direction}_pipeline_id"),
      pipeline_name: transition.public_send("#{direction}_pipeline_name"),
      stage_id: transition.public_send("#{direction}_stage_id"),
      stage_name: transition.public_send("#{direction}_stage_name"),
      stage_outcome: transition.public_send("#{direction}_stage_outcome")
    }
  end

  def overall_coverage(earliest_reliable_since)
    return 'unknown_before' if earliest_reliable_since.blank? || from_time < earliest_reliable_since
    return 'estimated' if relation.exists?(reliability: 'estimated')

    'exact'
  end
end
