class Crm::Reports::ConversionsQuery < Crm::Reports::StageVisitsQuery # rubocop:disable Metrics/ClassLength
  QUERY_KIND = 'conversions'.freeze
  FILTER_KEYS = %i[pipeline_id].freeze
  FILTER_COLUMNS = { pipeline_id: 'pipeline_id' }.freeze
  OUTCOMES = %w[won lost unconverted].freeze
  SOURCE = 'crm_stage_visits+crm_events'.freeze
  GROUP_COLUMNS = %w[cohort_pipeline_id cohort_pipeline_name].freeze

  attr_reader :as_of_time

  def initialize(...)
    super
    normalize_observation_window!
    normalize_fact_filters!
  end

  def aggregate_rows
    grouped_counts.map { |values| aggregate_payload(values) }
  end

  def aggregate_payload(values)
    dimensions = GROUP_COLUMNS.zip(values.shift(GROUP_COLUMNS.length)).to_h.symbolize_keys
    cohort_count, won_count, lost_count, unconverted_count, exact_count, estimated_count, unknown_count,
      unknown_loss_reason_count, not_configured_loss_reason_count, reliable_since = values

    dimensions.merge(
      cohort_count: cohort_count.to_i,
      won_count: won_count.to_i,
      lost_count: lost_count.to_i,
      unconverted_count: unconverted_count.to_i,
      conversion_rate_percent: conversion_rate(won_count, cohort_count, unknown_count),
      exact_count: exact_count.to_i,
      estimated_count: estimated_count.to_i,
      unknown_count: unknown_count.to_i,
      loss_reasons: loss_reasons_by_pipeline.fetch(dimensions[:cohort_pipeline_id], []),
      unknown_loss_reason_count: unknown_loss_reason_count.to_i,
      not_configured_loss_reason_count: not_configured_loss_reason_count.to_i,
      reliable_since: reliable_since&.utc&.iso8601(6),
      coverage: coverage_for(unknown_count, estimated_count)
    )
  end

  def drill_down_rows
    paginated_relation(relation, order: { cohort_entered_at: :desc, id: :desc }).map { |fact| drill_down_payload(fact) }
  end

  def total_count
    relation.count
  end

  def meta
    reliable_since = relation.maximum(:fact_reliable_since)
    base_meta(
      reliable_since: reliable_since,
      coverage: overall_coverage
    ).merge(
      as_of: as_of_time.utc.iso8601(6),
      as_of_local: as_of_time.iso8601(6),
      cohort_definition: 'first_stage_visit_entered_in_window',
      outcome_definition: 'first_terminal_stage_visit_observed_by_as_of',
      conversion_definition: 'won_cohort_deals_divided_by_all_cohort_deals',
      window_fact: 'cohort_entered_at',
      source: SOURCE
    )
  end

  def pagination_meta
    meta.merge(page: page, per_page: per_page, total_count: total_count)
  end

  def relation
    @relation ||= Crm::StageVisit.unscoped.from("(#{filtered_sql}) crm_stage_visits")
  end

  private

  def normalize_observation_window!
    value = params[:as_of_date]
    raise_validation!('as_of_date is required') if value.blank?
    raise_validation!('as_of_date must use YYYY-MM-DD') unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    date = Date.iso8601(value.to_s)
    cohort_end_date = to_time.in_time_zone(timezone).to_date
    raise_validation!('as_of_date must be on or after to_date') if date < cohort_end_date - 1.day

    exclusive_date = date + 1.day
    @as_of_time = ActiveSupport::TimeZone[timezone].local(exclusive_date.year, exclusive_date.month, exclusive_date.day)
  rescue Date::Error
    raise_validation!('as_of_date must be a valid date')
  end

  def normalize_fact_filters!
    @outcome = params[:outcome].presence&.to_s
    @closing_reason = params[:closing_reason].presence&.to_s&.strip
    validate_outcome_filter!
    validate_closing_reason_filter!
  end

  def validate_outcome_filter!
    raise_validation!('outcome is invalid') if @outcome.present? && !@outcome.in?(OUTCOMES)
  end

  def validate_closing_reason_filter!
    return if @closing_reason.blank?

    raise_validation!('closing_reason must not exceed 100 characters') if @closing_reason.length > 100
    raise_validation!('closing_reason requires outcome=lost') unless @outcome == 'lost'
  end

  def filtered_sql # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    <<~SQL.squish
      WITH ordered_visits AS (
        SELECT
          visits.*,
          ROW_NUMBER() OVER (PARTITION BY visits.deal_id ORDER BY visits.entered_at ASC, visits.id ASC) AS visit_number
        FROM crm_stage_visits visits
        INNER JOIN (#{visible_deals_sql}) visible_deals ON visible_deals.id = visits.deal_id
        WHERE visits.account_id = #{connection.quote(account.id)}
      ), cohorts AS (
        SELECT *
        FROM ordered_visits
        WHERE visit_number = 1
          AND entered_at >= #{connection.quote(from_time.utc)}
          AND entered_at < #{connection.quote(to_time.utc)}
          #{cohort_filter_sql}
      ), terminal_visits AS (
        SELECT
          visits.*,
          ROW_NUMBER() OVER (PARTITION BY visits.deal_id ORDER BY visits.entered_at ASC, visits.id ASC) AS terminal_number
        FROM crm_stage_visits visits
        INNER JOIN cohorts ON cohorts.deal_id = visits.deal_id
        WHERE visits.account_id = #{connection.quote(account.id)}
          AND visits.stage_outcome IN ('won', 'lost')
          AND visits.entered_at < #{connection.quote(as_of_time.utc)}
      ), facts AS (
        SELECT
          cohorts.id AS cohort_visit_id,
          cohorts.deal_id,
          cohorts.pipeline_id AS cohort_pipeline_id,
          cohorts.pipeline_name AS cohort_pipeline_name,
          cohorts.stage_id AS cohort_stage_id,
          cohorts.stage_name AS cohort_stage_name,
          cohorts.stage_outcome AS cohort_stage_outcome,
          cohorts.entered_at AS cohort_entered_at,
          terminals.id AS terminal_visit_id,
          terminals.pipeline_id AS terminal_pipeline_id,
          terminals.pipeline_name AS terminal_pipeline_name,
          terminals.stage_id AS terminal_stage_id,
          terminals.stage_name AS terminal_stage_name,
          terminals.stage_outcome AS terminal_stage_outcome,
          terminals.entered_at AS terminal_entered_at,
          GREATEST(cohorts.reliable_since, terminals.reliable_since) AS fact_reliable_since,
          COALESCE(events.closing_reasons, '[]'::jsonb) AS closing_reasons,
          events.id IS NOT NULL AS reason_known,
          events.schema_version AS event_schema_version,
          CASE WHEN terminals.id IS NULL THEN 'unconverted' ELSE terminals.stage_outcome END AS outcome,
          CASE
            WHEN cohorts.entered_at < cohorts.reliable_since
              OR terminals.entered_at < terminals.reliable_since THEN 'unknown'
            WHEN cohorts.estimated OR COALESCE(terminals.estimated, FALSE) THEN 'estimated'
            ELSE 'exact'
          END AS reliability
        FROM cohorts
        LEFT JOIN terminal_visits terminals
          ON terminals.deal_id = cohorts.deal_id AND terminals.terminal_number = 1
        LEFT JOIN LATERAL (
          SELECT event.id, event.schema_version, event.after_data->'closing_reasons' AS closing_reasons
          FROM crm_events event
          WHERE event.account_id = #{connection.quote(account.id)}
            AND event.eventable_type = 'Crm::Deal'
            AND event.eventable_id = cohorts.deal_id
            AND event.event_type = 'deal_stage_changed'
            AND event.correlation_id = terminals.correlation_id
            AND event.schema_version = 1
            AND jsonb_typeof(event.after_data->'closing_reasons') = 'array'
          ORDER BY event.id DESC
          LIMIT 1
        ) events ON TRUE
      )
      SELECT facts.cohort_visit_id AS id, facts.*
      FROM facts
      WHERE #{fact_filter_predicates.join(' AND ')}
    SQL
  end

  def cohort_filter_sql
    return '' if filters.empty?

    "AND #{filter_predicates.join(' AND ')}"
  end

  def fact_filter_predicates
    predicates = ['TRUE']
    predicates << "outcome = #{connection.quote(@outcome)}" if @outcome.present?
    if @closing_reason.present?
      reason_json = [@closing_reason].to_json
      predicates << "reason_known AND closing_reasons @> #{connection.quote(reason_json)}::jsonb"
    end
    predicates
  end

  def grouped_counts
    relation.group(:cohort_pipeline_id, :cohort_pipeline_name).pluck(
      :cohort_pipeline_id,
      :cohort_pipeline_name,
      Arel.sql('COUNT(*)'),
      Arel.sql("COUNT(*) FILTER (WHERE outcome = 'won')"),
      Arel.sql("COUNT(*) FILTER (WHERE outcome = 'lost')"),
      Arel.sql("COUNT(*) FILTER (WHERE outcome = 'unconverted')"),
      Arel.sql("COUNT(*) FILTER (WHERE reliability = 'exact')"),
      Arel.sql("COUNT(*) FILTER (WHERE reliability = 'estimated')"),
      Arel.sql("COUNT(*) FILTER (WHERE reliability = 'unknown')"),
      Arel.sql("COUNT(*) FILTER (WHERE outcome = 'lost' AND NOT reason_known)"),
      Arel.sql("COUNT(*) FILTER (WHERE outcome = 'lost' AND reason_known AND closing_reasons = '[]'::jsonb)"),
      Arel.sql('MAX(fact_reliable_since)')
    )
  end

  def loss_reasons_by_pipeline
    @loss_reasons_by_pipeline ||= relation.where(outcome: 'lost', reason_known: true)
                                          .joins(loss_reason_join_sql)
                                          .group(:cohort_pipeline_id, 'loss_reason.value')
                                          .pluck(:cohort_pipeline_id, 'loss_reason.value', Arel.sql('COUNT(*)'))
                                          .group_by(&:first)
                                          .transform_values { |rows| reason_rows(rows) }
  end

  def loss_reason_join_sql
    'CROSS JOIN LATERAL jsonb_array_elements_text(closing_reasons) loss_reason(value)'
  end

  def reason_rows(rows)
    rows.map { |_, reason, count| { reason: reason, deal_count: count } }
        .sort_by { |row| [-row[:deal_count], row[:reason]] }
  end

  def conversion_rate(won_count, cohort_count, unknown_count)
    return if cohort_count.to_i.zero? || unknown_count.to_i.positive?

    ((won_count.to_f / cohort_count) * 100).round(3)
  end

  def coverage_for(unknown_count, estimated_count)
    return 'unknown' if unknown_count.to_i.positive?
    return 'estimated' if estimated_count.to_i.positive?

    'exact'
  end

  def overall_coverage
    return 'unknown' if !relation.exists? || relation.exists?(reliability: 'unknown')
    return 'estimated' if relation.exists?(reliability: 'estimated')

    'exact'
  end

  def drill_down_payload(fact)
    {
      cohort_visit_id: fact.cohort_visit_id,
      deal_id: fact.deal_id,
      cohort: snapshot_payload(fact, :cohort, entered_at: :cohort_entered_at),
      terminal: terminal_payload(fact),
      outcome: fact.outcome,
      closing_reasons: fact.reason_known ? fact.closing_reasons : nil,
      closing_reasons_reliability: closing_reasons_reliability(fact),
      reliability: fact.reliability,
      reliable_since: fact.fact_reliable_since&.utc&.iso8601(6)
    }
  end

  def terminal_payload(fact)
    return if fact.terminal_visit_id.blank?

    snapshot_payload(fact, :terminal, entered_at: :terminal_entered_at).merge(stage_visit_id: fact.terminal_visit_id)
  end

  def snapshot_payload(fact, prefix, entered_at:)
    {
      pipeline_id: fact.public_send("#{prefix}_pipeline_id"),
      pipeline_name: fact.public_send("#{prefix}_pipeline_name"),
      stage_id: fact.public_send("#{prefix}_stage_id"),
      stage_name: fact.public_send("#{prefix}_stage_name"),
      stage_outcome: fact.public_send("#{prefix}_stage_outcome"),
      entered_at: fact.public_send(entered_at)&.utc&.iso8601(6)
    }
  end

  def closing_reasons_reliability(fact)
    return 'not_applicable' unless fact.outcome == 'lost'
    return 'unknown' unless fact.reason_known

    'exact'
  end

  def query_fingerprint
    @query_fingerprint ||= Digest::SHA256.hexdigest(
      [
        QUERY_KIND, account.id, visible_deals_sql, from_time.utc.iso8601(6), to_time.utc.iso8601(6),
        as_of_time.utc.iso8601(6), filters.sort, @outcome, @closing_reason
      ].to_json
    )
  end
end
