require 'digest'

# Counts recorded transitions, not a historical SLA, duration, or complete pre-cutover event total.
class CommunicationThreads::StateTransitionOccurrencesQuery # rubocop:disable Metrics/ClassLength
  class InvalidQuery < StandardError; end

  MAX_WINDOW_DAYS = 366
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100
  MAX_PAGE = 10_000
  DIMENSIONS = %w[owner team].freeze
  UNASSIGNED = 'unassigned'.freeze
  QUERY_KIND = 'communication_thread_state_transition_occurrences'.freeze
  SOURCE = 'communication_thread_state_transition_facts'.freeze
  ALLOWED_PARAMS = %i[from_date to_date dimension event_kind owner_id team_id page per_page].freeze

  attr_reader :account, :generated_at, :timezone, :from_time, :to_time, :dimension

  def initialize(account:, user_context:, params: {}, generated_at: Time.current)
    @account = account
    @user_context = user_context
    @params = params.to_h.symbolize_keys
    @generated_at = generated_at
    @timezone = account.workspace_working_hours_timezone
    @zone = ActiveSupport::TimeZone[timezone]
    raise_invalid!('workspace timezone is invalid') unless @zone

    authorize!
    normalize_params!
  end

  def aggregate_rows = aggregate_result.fetch(:rows)
  def drill_down_rows = details_result.fetch(:rows)
  def meta = report_meta(aggregate_result.fetch(:totals))
  def pagination_meta = report_meta(details_result.fetch(:totals)).merge(page: page, per_page: per_page)

  # Both representations use the same authorized, account-qualified, retained-fact relation.
  # A deleted Thread or a Thread whose current Contact/display identity no longer matches
  # the fact cannot become a historical-identity oracle.
  def relation
    @relation ||= apply_attribution_filter(base_relation)
  end

  private

  attr_reader :params, :user_context, :zone, :filters

  def base_relation
    @base_relation ||= begin
      facts = CommunicationThreadStateTransitionFact.where(account_id: account.id, occurred_at: from_time...to_time)
                                                    .where('communication_thread_state_transition_facts.occurred_at <= ?', generated_at)
                                                    .where('communication_thread_state_transition_facts.created_at <= ?', generated_at)
      facts = facts.joins(<<~SQL.squish)
        INNER JOIN communication_threads visible_threads
          ON visible_threads.id = communication_thread_state_transition_facts.communication_thread_id_snapshot
          AND visible_threads.account_id = communication_thread_state_transition_facts.account_id
          AND visible_threads.contact_id = communication_thread_state_transition_facts.contact_id_snapshot
          AND visible_threads.display_id = communication_thread_state_transition_facts.thread_display_id_snapshot
        INNER JOIN contacts visible_contacts
          ON visible_contacts.id = visible_threads.contact_id
          AND visible_contacts.account_id = communication_thread_state_transition_facts.account_id
      SQL
      facts = facts.where(communication_thread_id_snapshot: visible_threads.select(:id))
      facts = facts.where(event_kind: filters[:event_kind]) if filters.key?(:event_kind)
      facts
    end
  end

  def authorize!
    return if valid_member? && account.feature_enabled?('communication_threads') &&
              CommunicationThreadPolicy.new(user_context, CommunicationThread).view_reports?

    raise Pundit::NotAuthorizedError, 'communication thread reports are not authorized'
  end

  def valid_member?
    member = user_context[:account_user]
    user_context[:account]&.id == account.id && member&.account_id == account.id &&
      member.user_id == user_context[:user]&.id &&
      AccountUser.exists?(id: member.id, account_id: account.id, user_id: member.user_id)
  end

  def visible_threads
    @visible_threads ||= CommunicationThreadPolicy::Scope.intersection(
      user_context, CommunicationThread.where(account_id: account.id), capabilities: %w[view view_reports]
    )
  end

  def normalize_params!
    unsupported = params.keys - ALLOWED_PARAMS
    raise_invalid!('unsupported report parameter') if unsupported.any?

    normalize_window!
    normalize_filters!
    page
    per_page
  end

  def normalize_window!
    from_date = parse_date!(:from_date)
    to_date = parse_date!(:to_date)
    days = (to_date - from_date).to_i + 1
    raise_invalid!('to_date must be on or after from_date') if days < 1
    raise_invalid!("date window must not exceed #{MAX_WINDOW_DAYS} days") if days > MAX_WINDOW_DAYS

    @from_time = zone.local(from_date.year, from_date.month, from_date.day)
    exclusive_date = to_date + 1.day
    @to_time = zone.local(exclusive_date.year, exclusive_date.month, exclusive_date.day)
  end

  def normalize_filters! # rubocop:disable Metrics/CyclomaticComplexity
    @dimension = params[:dimension].presence&.to_s
    raise_invalid!('dimension must be owner or team') if dimension.present? && DIMENSIONS.exclude?(dimension)

    @filters = { event_kind: parse_event_kind!, owner_id: parse_attribution!(:owner_id),
                 team_id: parse_attribution!(:team_id) }.compact
    raise_invalid!('dimension=owner is required with owner_id') if filters.key?(:owner_id) && dimension != 'owner'
    raise_invalid!('dimension=team is required with team_id') if filters.key?(:team_id) && dimension != 'team'
    validate_attribution!(:owner_id, :to_assignee_id)
    validate_attribution!(:team_id, :to_team_id)
  end

  def parse_date!(key)
    value = params[key]
    raise_invalid!("#{key} is required") if value.blank?
    raise_invalid!("#{key} must use YYYY-MM-DD") unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.iso8601(value.to_s)
  rescue Date::Error
    raise_invalid!("#{key} must be a valid date")
  end

  def parse_event_kind!
    return if params[:event_kind].blank?

    value = params[:event_kind].to_s
    raise_invalid!('event_kind is invalid') unless CommunicationThreadStateTransitionFact::EVENT_KINDS.include?(value)

    value
  end

  def parse_attribution!(key)
    return if params[key].blank?
    return UNASSIGNED if params[key].to_s == UNASSIGNED

    parse_positive_integer!(key, default: nil)
  end

  def validate_attribution!(key, column)
    return unless filters.key?(key) && filters[key] != UNASSIGNED

    # Visible *historical* snapshots, not mutable present-day memberships or Team rows.
    # A hidden or foreign ID produces the same rejection without revealing its existence.
    raise_invalid!("#{key} is invalid") unless base_relation.exists?(column => filters[key])
  end

  def apply_attribution_filter(scope)
    %i[owner_id team_id].reduce(scope) do |current, key|
      next current unless filters.key?(key)

      column = key == :owner_id ? :to_assignee_id : :to_team_id
      current.where(column => filters[key] == UNASSIGNED ? nil : filters[key])
    end
  end

  def report_relation
    relation.reselect('communication_thread_state_transition_facts.*').reorder(nil)
  end

  def totals_sql
    <<~SQL.squish
      SELECT COUNT(*) AS observed_count, MIN(reliable_since) AS first_observed_reliable_since,
        COUNT(*) FILTER (WHERE source = 'database_projection_fallback') AS fallback_count,
        COUNT(*) FILTER (WHERE source_version <> 1) AS unknown_version_count
      FROM matching_facts
    SQL
  end

  def aggregate_sql
    buckets = selected_dimensions.map { |value| dimension_sql(value) }.join(' UNION ALL ')
    <<~SQL.squish
      WITH matching_facts AS MATERIALIZED (#{report_relation.to_sql})
      SELECT buckets.*, totals.* FROM (#{totals_sql}) totals
      LEFT JOIN LATERAL (#{buckets}) buckets ON TRUE
      ORDER BY buckets.dimension ASC, buckets.dimension_id ASC NULLS FIRST
    SQL
  end

  def dimension_sql(value)
    key = value == 'owner' ? 'assignee' : 'team'
    <<~SQL.squish
      SELECT #{connection.quote(value)} AS dimension, facts.to_#{key}_id AS dimension_id,
        (ARRAY_AGG(facts.to_#{key}_name ORDER BY facts.occurred_at DESC, facts.id DESC))[1] AS name_snapshot,
        COUNT(*) AS occurrence_count,
        COUNT(*) FILTER (WHERE facts.event_kind = 'created') AS created_count,
        COUNT(*) FILTER (WHERE facts.event_kind = 'resolved') AS resolved_count,
        COUNT(*) FILTER (WHERE facts.event_kind = 'reopened') AS reopened_count,
        COUNT(*) FILTER (WHERE facts.from_#{key}_id IS NULL AND facts.to_#{key}_id IS NOT NULL) AS assigned_count,
        COUNT(*) FILTER (WHERE facts.from_#{key}_id IS NOT NULL AND facts.to_#{key}_id IS NULL) AS unassigned_count,
        COUNT(*) FILTER (WHERE facts.from_#{key}_id IS NOT NULL AND facts.to_#{key}_id IS NOT NULL
          AND facts.from_#{key}_id <> facts.to_#{key}_id) AS reassigned_count
      FROM matching_facts facts
      GROUP BY facts.to_#{key}_id
    SQL
  end

  def details_sql
    <<~SQL.squish
      WITH matching_facts AS MATERIALIZED (#{report_relation.to_sql})
      SELECT page.*, totals.* FROM (#{totals_sql}) totals
      LEFT JOIN LATERAL (
        SELECT facts.* FROM matching_facts facts
        ORDER BY facts.occurred_at DESC, facts.id DESC
        LIMIT #{per_page} OFFSET #{(page - 1) * per_page}
      ) page ON TRUE
    SQL
  end

  def aggregate_result
    @aggregate_result ||= begin
      records = connection.exec_query(aggregate_sql).to_a
      { rows: records.filter_map { |row| aggregate_payload(row) if row['dimension'] }, totals: records.first }
    end
  end

  def details_result
    @details_result ||= begin
      records = connection.exec_query(details_sql).to_a
      { rows: records.filter_map { |row| detail_payload(row) if row['id'] }, totals: records.first }
    end
  end

  def aggregate_payload(row)
    {
      dimension: row['dimension'],
      attribution: attribution(row['dimension_id'], row['name_snapshot']),
      **%w[occurrence_count created_count resolved_count reopened_count assigned_count unassigned_count reassigned_count]
        .index_with { |key| row[key].to_i }.symbolize_keys
    }
  end

  def detail_payload(row) # rubocop:disable Metrics/AbcSize
    {
      fact_id: row['id'], communication_thread_id: row['communication_thread_id_snapshot'],
      display_id: row['thread_display_id_snapshot'], contact_id: row['contact_id_snapshot'],
      event_kind: row['event_kind'], occurred_at: iso8601(row['occurred_at']),
      reliable_since: iso8601(row['reliable_since']), source_version: row['source_version'],
      source: row['source'], source_event_id: row['source_event_id'],
      from_owner: attribution(row['from_assignee_id'], row['from_assignee_name']),
      to_owner: attribution(row['to_assignee_id'], row['to_assignee_name']),
      from_team: attribution(row['from_team_id'], row['from_team_name']),
      to_team: attribution(row['to_team_id'], row['to_team_name']),
      from_status: row['from_status'], to_status: row['to_status'],
      owner_transition: transition(row, 'assignee'), team_transition: transition(row, 'team'),
      actor: { kind: row['actor_kind'], id: row['actor_id'], name_snapshot: row['actor_name'] }
    }
  end

  def transition(row, key) # rubocop:disable Metrics/CyclomaticComplexity
    from = row["from_#{key}_id"]
    to = row["to_#{key}_id"]
    return 'assigned' if from.nil? && to.present?
    return 'unassigned' if from.present? && to.nil?
    return 'reassigned' if from.present? && to.present? && from != to

    'unchanged'
  end

  def attribution(id, name)
    state = if id.nil?
              'not_configured'
            elsif name.present?
              'persisted_snapshot'
            else
              'unknown_snapshot_name'
            end
    { id: id, name_snapshot: id.nil? ? nil : name, state: state }
  end

  def report_meta(totals) # rubocop:disable Metrics/AbcSize
    count = totals.fetch('observed_count').to_i
    {
      metric_kind: 'immutable_transition_occurrences', source: SOURCE, definition_version: 1, source_version: 1,
      generated_at: generated_at.utc.iso8601(6), generated_at_local: generated_at.in_time_zone(zone).iso8601(6),
      timezone: timezone, from: from_time.utc.iso8601(6), to: to_time.utc.iso8601(6),
      from_local: from_time.iso8601(6), to_local: to_time.iso8601(6),
      observed_count: count, total_count: count, occurrence_total: nil,
      coverage: count.zero? ? 'unknown' : 'partial', verified_writer_cutover_at: nil,
      first_observed_reliable_since: iso8601(totals['first_observed_reliable_since']),
      fallback_count: totals.fetch('fallback_count').to_i, unknown_version_count: totals.fetch('unknown_version_count').to_i,
      query_fingerprint: query_fingerprint,
      cohort_definition: 'currently_retained_account_thread_and_contact_view_intersect_view_reports_owner_scope_at_generated_at',
      temporal_definition: 'workspace_local_half_open_occurrence_window_observed_at_generated_at',
      attribution_definition: 'immutable_from_to_canonical_thread_owner_and_team_snapshots_not_actor_or_conversation_assignee',
      coverage_definition: 'observed_facts_only_no_verified_deployment_and_drain_cutover_no_legacy_backfill_or_exact_empty_zero',
      effectiveness_state: 'historical_sla_duration_rates_and_denominator_not_supported',
      combination_definition: 'owner_and_team_dimensions_must_not_be_summed'
    }
  end

  def selected_dimensions = dimension.present? ? [dimension] : DIMENSIONS
  def page = @page ||= parse_positive_integer!(:page, default: 1, max: MAX_PAGE)
  def per_page = @per_page ||= parse_positive_integer!(:per_page, default: DEFAULT_PER_PAGE, max: MAX_PER_PAGE)

  def parse_positive_integer!(key, default:, max: nil)
    value = params[key].presence || default
    raise_invalid!("#{key} must be a positive integer") unless value.to_s.match?(/\A[1-9]\d*\z/)

    parsed = value.to_i
    raise_invalid!("#{key} must not exceed #{max}") if max && parsed > max
    parsed
  end

  def query_fingerprint
    @query_fingerprint ||= Digest::SHA256.hexdigest(
      [QUERY_KIND, account.id, visible_threads.to_sql, from_time.utc.iso8601(6), to_time.utc.iso8601(6),
       generated_at.utc.iso8601(6), dimension, filters.sort].to_json
    )
  end

  def iso8601(value) = value&.utc&.iso8601(6)
  def connection = ActiveRecord::Base.connection
  def raise_invalid!(message) = raise InvalidQuery, message
end
