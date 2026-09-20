class Crm::Reports::TaskResultsQuery # rubocop:disable Metrics/ClassLength
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100
  QUERY_KIND = 'task_results'.freeze
  SOURCE = 'crm_events.task_terminal_catalog_snapshots'.freeze
  RELIABILITIES = %w[exact estimated unknown].freeze

  attr_reader :account, :params

  def initialize(account:, tasks_scope:, params: {})
    @account = account
    @params = params.to_h.symbolize_keys
    @lifecycle_query = Crm::Reports::TaskLifecycleQuery.new(
      account: account,
      tasks_scope: tasks_scope,
      params: @params.slice(:from_date, :to_date, :as_of_date)
    )
    normalize_filters!
  end

  def aggregate_rows
    grouped_counts.map { |values| aggregate_payload(values) }
  end

  def drill_down_rows
    paginated_relation.map { |fact| drill_down_payload(fact) }
  end

  def total_count
    relation.count
  end

  def meta
    window_metadata.merge(
      query_fingerprint: query_fingerprint,
      definition_version: 1,
      source: SOURCE,
      reliable_since: nil,
      unknown_before: nil,
      reliability_boundary: 'per_fact_only',
      coverage: overall_coverage
    ).merge(metric_definitions)
  end

  def pagination_meta
    meta.merge(page: page, per_page: per_page, total_count: total_count)
  end

  private

  attr_reader :lifecycle_query, :task_type_id, :task_outcome_id, :lifecycle_type, :reliability

  def normalize_filters!
    @task_type_id = parse_optional_positive_integer!(:task_type_id)
    @task_outcome_id = parse_optional_positive_integer!(:task_outcome_id)
    @lifecycle_type = params[:lifecycle_type].presence&.to_s
    @reliability = params[:reliability].presence&.to_s
    raise_validation!('lifecycle_type is invalid') if lifecycle_type.present? && !lifecycle_type.in?(%w[completed cancelled])
    raise_validation!('reliability is invalid') if reliability.present? && !reliability.in?(RELIABILITIES)

    validate_catalog_filters!
  end

  def validate_catalog_filters!
    task_type = validated_task_type_filter
    outcome = validated_task_outcome_filter
    return unless task_type && outcome && outcome.task_type_id != task_type.id

    raise_validation!('task_outcome_id does not belong to task_type_id')
  end

  def validated_task_type_filter
    return unless task_type_id

    account.crm_task_types.find_by(id: task_type_id) || raise_validation!('task_type_id is invalid')
  end

  def validated_task_outcome_filter
    return unless task_outcome_id

    account.crm_task_outcomes.find_by(id: task_outcome_id) || raise_validation!('task_outcome_id is invalid')
  end

  def relation
    @relation ||= begin
      scope = Crm::Event.unscoped.from("(#{result_facts_sql}) task_result_facts").select('task_result_facts.*')
      scope = scope.where(task_result_facts: { task_type_id: task_type_id }) if task_type_id
      scope = scope.where(task_result_facts: { task_outcome_id: task_outcome_id }) if task_outcome_id
      scope = scope.where(task_result_facts: { lifecycle_type: lifecycle_type }) if lifecycle_type.present?
      scope = scope.where(task_result_facts: { fact_reliability: reliability }) if reliability.present?
      scope
    end
  end

  def result_facts_sql
    <<~SQL.squish
      SELECT catalog_facts.*,
        CASE
          WHEN catalog_facts.lifecycle_reliability = 'unknown'
            OR catalog_facts.task_type_reliability = 'unknown'
            OR catalog_facts.task_outcome_reliability = 'unknown' THEN 'unknown'
          WHEN catalog_facts.lifecycle_reliability = 'estimated'
            OR catalog_facts.task_type_reliability = 'estimated'
            OR catalog_facts.task_outcome_reliability = 'estimated' THEN 'estimated'
          ELSE 'exact'
        END AS fact_reliability
      FROM (#{catalog_facts_sql}) catalog_facts
    SQL
  end

  def catalog_facts_sql # rubocop:disable Metrics/MethodLength
    <<~SQL.squish
      SELECT lifecycle_facts.*,
        task_types.id AS task_type_id,
        task_types.code AS task_type_code,
        task_types.name AS task_type_name,
        CASE WHEN task_types.id IS NOT NULL THEN 'catalog' ELSE 'unknown' END AS task_type_kind,
        CASE WHEN task_types.id IS NOT NULL THEN 'exact' ELSE 'unknown' END AS task_type_reliability,
        CASE
          WHEN task_types.id IS NOT NULL THEN 'terminal_event.task_type_id+current_catalog'
          WHEN NULLIF(lifecycle_facts.task_type_id_snapshot, '') IS NULL THEN 'terminal_event.missing_task_type_id'
          ELSE 'terminal_event.invalid_task_type_id'
        END AS task_type_source,
        task_outcomes.id AS task_outcome_id,
        CASE
          WHEN task_outcomes.id IS NOT NULL THEN task_outcomes.code
          WHEN NULLIF(lifecycle_facts.task_outcome_id_snapshot, '') IS NULL
            THEN NULLIF(lifecycle_facts.legacy_outcome_snapshot, '')
        END AS task_outcome_code,
        task_outcomes.name AS task_outcome_name,
        CASE
          WHEN task_outcomes.id IS NOT NULL THEN 'catalog'
          WHEN NULLIF(lifecycle_facts.task_outcome_id_snapshot, '') IS NULL
            AND NULLIF(lifecycle_facts.legacy_outcome_snapshot, '') IS NOT NULL THEN 'legacy_snapshot'
          WHEN NULLIF(lifecycle_facts.task_outcome_id_snapshot, '') IS NULL
            AND NULLIF(lifecycle_facts.legacy_outcome_snapshot, '') IS NULL
            AND lifecycle_facts.lifecycle_type = 'cancelled' THEN 'not_configured'
          ELSE 'unknown'
        END AS task_outcome_kind,
        CASE
          WHEN task_outcomes.id IS NOT NULL THEN 'exact'
          WHEN NULLIF(lifecycle_facts.task_outcome_id_snapshot, '') IS NULL
            AND NULLIF(lifecycle_facts.legacy_outcome_snapshot, '') IS NOT NULL THEN 'estimated'
          WHEN NULLIF(lifecycle_facts.task_outcome_id_snapshot, '') IS NULL
            AND NULLIF(lifecycle_facts.legacy_outcome_snapshot, '') IS NULL
            AND lifecycle_facts.lifecycle_type = 'cancelled' THEN 'exact'
          ELSE 'unknown'
        END AS task_outcome_reliability,
        CASE
          WHEN task_outcomes.id IS NOT NULL THEN 'terminal_event.task_outcome_id+current_catalog'
          WHEN NULLIF(lifecycle_facts.task_outcome_id_snapshot, '') IS NULL
            AND NULLIF(lifecycle_facts.legacy_outcome_snapshot, '') IS NOT NULL THEN 'terminal_event.legacy_outcome_code'
          WHEN NULLIF(lifecycle_facts.task_outcome_id_snapshot, '') IS NULL
            AND NULLIF(lifecycle_facts.legacy_outcome_snapshot, '') IS NULL
            AND lifecycle_facts.lifecycle_type = 'cancelled' THEN 'terminal_event.not_configured'
          WHEN NULLIF(lifecycle_facts.task_outcome_id_snapshot, '') IS NULL THEN 'terminal_event.missing_task_outcome'
          ELSE 'terminal_event.invalid_task_outcome_id'
        END AS task_outcome_source
      FROM (#{lifecycle_query.fact_relation.to_sql}) lifecycle_facts
      LEFT JOIN crm_task_types task_types
        ON task_types.id = #{snapshot_id_sql('lifecycle_facts.task_type_id_snapshot')}
        AND task_types.account_id = #{connection.quote(account.id)}
      LEFT JOIN crm_task_outcomes task_outcomes
        ON task_outcomes.id = #{snapshot_id_sql('lifecycle_facts.task_outcome_id_snapshot')}
        AND task_outcomes.account_id = #{connection.quote(account.id)}
        AND task_outcomes.task_type_id = task_types.id
    SQL
  end

  def valid_snapshot_id_sql(expression)
    "#{expression} ~ '^[1-9]\\d*$' AND COALESCE(pg_input_is_valid(#{expression}, 'bigint'), FALSE)"
  end

  def snapshot_id_sql(expression)
    "CASE WHEN #{valid_snapshot_id_sql(expression)} THEN #{expression}::bigint END"
  end

  def grouped_counts
    columns = grouping_columns.map { |column| Arel.sql("task_result_facts.#{column}") }
    order = ordering_columns.map { |column| Arel.sql("task_result_facts.#{column}") }
    relation.unscope(:select).group(*columns).order(*order).pluck(
      *columns,
      Arel.sql('COUNT(*)'),
      Arel.sql("COUNT(*) FILTER (WHERE fact_reliability = 'exact')"),
      Arel.sql("COUNT(*) FILTER (WHERE fact_reliability = 'estimated')"),
      Arel.sql("COUNT(*) FILTER (WHERE fact_reliability = 'unknown')")
    )
  end

  def grouping_columns
    %w[
      lifecycle_type schema_version task_type_id task_type_code task_type_name task_type_kind
      task_type_reliability task_type_source task_outcome_id task_outcome_code task_outcome_name
      task_outcome_kind task_outcome_reliability task_outcome_source
    ]
  end

  def ordering_columns
    %w[lifecycle_type task_type_id task_type_code task_outcome_id task_outcome_code schema_version]
  end

  def aggregate_payload(values)
    lifecycle, version, *dimension_values, count, exact_count, estimated_count, unknown_count = values
    type_values = dimension_values.shift(6)
    outcome_values = dimension_values.shift(6)
    {
      lifecycle_type: lifecycle,
      snapshot_schema_version: version,
      task_type: dimension_payload(type_values),
      task_outcome: dimension_payload(outcome_values),
      occurrence_count: count.to_i,
      exact_count: exact_count.to_i,
      estimated_count: estimated_count.to_i,
      unknown_count: unknown_count.to_i,
      coverage: coverage_for(estimated_count, unknown_count)
    }
  end

  def dimension_payload(values)
    id, code, name, kind, dimension_reliability, source = values
    {
      id: id,
      code: code,
      name: name,
      kind: kind,
      reliability: dimension_reliability,
      source: source,
      label_semantics: label_semantics(id, kind)
    }
  end

  def label_semantics(id, kind)
    return 'current_catalog_projection' if id
    return 'immutable_event_snapshot' if kind == 'legacy_snapshot'
    return 'explicit_not_configured' if kind == 'not_configured'

    'unavailable'
  end

  def paginated_relation
    relation.order(Arel.sql('task_result_facts.lifecycle_at DESC, task_result_facts.id DESC'))
            .offset((page - 1) * per_page).limit(per_page)
  end

  def drill_down_payload(fact)
    {
      lifecycle_event_id: fact.id,
      task_id: fact.task_id,
      lifecycle_type: fact.lifecycle_type,
      lifecycle_at: fact.lifecycle_at&.utc&.iso8601(6),
      snapshot_schema_version: fact.schema_version,
      task_type: dimension_payload(dimension_values(fact, :task_type)),
      task_outcome: dimension_payload(dimension_values(fact, :task_outcome)),
      reliability: fact.fact_reliability,
      correlation_id: fact.correlation_id
    }
  end

  def dimension_values(fact, prefix)
    %i[id code name kind reliability source].map { |suffix| fact.public_send("#{prefix}_#{suffix}") }
  end

  def metric_definitions
    {
      metric_definition: 'terminal_lifecycle_occurrences_grouped_by_persisted_task_type_and_task_outcome_identity',
      cohort_definition: 'terminal_lifecycle_occurrences_in_window_observed_by_as_of',
      window_fact: 'terminal_at_with_event_created_at_fallback',
      catalog_identity_definition: 'event_snapshot_foreign_key_with_account_and_type_validated_catalog_projection',
      legacy_outcome_definition: 'persisted_event_outcome_code_without_stable_catalog_identity',
      catalog_label_definition: 'current_catalog_projection_not_historical_name_or_code_snapshot'
    }
  end

  def window_metadata
    {
      timezone: lifecycle_query.timezone,
      from: lifecycle_query.from_time.utc.iso8601(6),
      to: lifecycle_query.to_time.utc.iso8601(6),
      from_local: lifecycle_query.from_time.iso8601(6),
      to_local: lifecycle_query.to_time.iso8601(6),
      as_of: lifecycle_query.as_of_time.utc.iso8601(6),
      as_of_local: lifecycle_query.as_of_time.iso8601(6)
    }
  end

  def coverage_for(estimated_count, unknown_count)
    return 'unknown' if unknown_count.to_i.positive?
    return 'estimated' if estimated_count.to_i.positive?

    'exact'
  end

  def overall_coverage
    return 'unknown' if !relation.exists? || relation.where("task_result_facts.fact_reliability = 'unknown'").exists?
    return 'estimated' if relation.where("task_result_facts.fact_reliability = 'estimated'").exists?

    'exact'
  end

  def page
    @page ||= parse_positive_integer!(:page, default: 1)
  end

  def per_page
    @per_page ||= parse_positive_integer!(:per_page, default: DEFAULT_PER_PAGE, max: MAX_PER_PAGE)
  end

  def parse_optional_positive_integer!(key)
    return if params[key].blank?

    parse_positive_integer!(key, default: nil)
  end

  def parse_positive_integer!(key, default:, max: nil)
    value = params[key].presence || default
    raise_validation!("#{key} must be a positive integer") unless value.to_s.match?(/\A[1-9]\d*\z/)

    parsed = value.to_i
    raise_validation!("#{key} must not exceed #{max}") if max && parsed > max
    parsed
  end

  def query_fingerprint
    @query_fingerprint ||= Digest::SHA256.hexdigest(
      [
        QUERY_KIND, account.id, lifecycle_query.fact_relation.to_sql,
        lifecycle_query.from_time.utc.iso8601(6), lifecycle_query.to_time.utc.iso8601(6),
        lifecycle_query.as_of_time.utc.iso8601(6), task_type_id, task_outcome_id, lifecycle_type, reliability
      ].to_json
    )
  end

  def connection
    ActiveRecord::Base.connection
  end

  def raise_validation!(message)
    raise Crm::Error.new(code: 'INVALID_REPORT_QUERY', message: message, status: :unprocessable_content)
  end
end
