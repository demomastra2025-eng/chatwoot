class CommunicationThreads::CollaborationOccurrencesQuery # rubocop:disable Metrics/ClassLength
  class InvalidQuery < StandardError; end

  MAX_WINDOW_DAYS = 366
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100
  MAX_PAGE = 10_000
  QUERY_KIND = 'communication_thread_collaboration_occurrences'.freeze
  FACT_KINDS = %w[participant_lifecycle authored_customer_reply private_message manual_call].freeze
  AVAILABLE_FACT_KINDS = FACT_KINDS.freeze

  attr_reader :account, :params, :timezone, :from_time, :to_time, :as_of_time, :fact_kind

  def initialize(account:, threads_scope:, params: {})
    @account = account
    @threads_scope = threads_scope
    @params = params.to_h.symbolize_keys
    @timezone = account.workspace_working_hours_timezone
    @zone = ActiveSupport::TimeZone[timezone]
    validate_zone!
    normalize_fact_kind!
    normalize_window!
    normalize_as_of!
  end

  def aggregate_rows
    grouped_counts.map do |values|
      fact, source, reliability, actor_kind, actor_type, actor_id, action,
        occurrence_count, distinct_thread_count, deleted_count = values
      {
        fact_kind: fact,
        source: source,
        reliability: reliability,
        actor: actor_payload(actor_kind, actor_type, actor_id),
        action: action,
        occurrence_count: occurrence_count.to_i,
        distinct_thread_count: distinct_thread_count.to_i,
        deleted_count: deleted_count.to_i
      }
    end
  end

  def drill_down_rows
    paginated_relation.map do |occurrence|
      {
        occurrence_id: occurrence.occurrence_id,
        communication_thread_id: occurrence.communication_thread_id,
        occurred_at: occurrence.occurred_at&.utc&.iso8601(6),
        fact_kind: occurrence.fact_kind,
        source: occurrence.source,
        reliability: occurrence.reliability,
        retention: occurrence.retention,
        actor: actor_payload(occurrence.actor_kind, occurrence.actor_type, occurrence.actor_id, occurrence.actor_name),
        action: occurrence.action,
        action_actor: action_actor_payload(occurrence),
        deleted: occurrence.attributes['deleted'],
        schema_version: occurrence.schema_version,
        reliable_since: occurrence.reliable_since&.utc&.iso8601(6),
        correlation_id: occurrence.correlation_id
      }
    end
  end

  def meta
    window_metadata.merge(
      total_count: relation.count,
      query_fingerprint: query_fingerprint,
      definition_version: 1,
      source_version: 1,
      fact_kind: fact_kind,
      source_contract: adapter.metadata,
      source_catalog: source_catalog,
      cohort_definition: 'visible_threads_from_communication_thread_view_intersect_view_reports_owner_scope',
      owner_definition: 'canonical_thread_owner_is_not_collaboration_actor_and_receives_no_credit_from_this_report',
      combination_definition: 'fact_kinds_are_source_specific_and_must_not_be_summed_as_employee_effectiveness',
      zero_definition: 'zero_is_returned_only_for_an_available_source_with_no_visible_retained_occurrences',
      missing_source_definition: 'unrecorded_manual_call_history_outside_the_durable_native_source_coverage_is_unknown_not_zero'
    )
  end

  def pagination_meta
    meta.merge(page: page, per_page: per_page)
  end

  def relation
    @relation ||= begin
      scoped_relation = adapter.relation
      raise_invalid!('manual_call occurrence coverage is unknown for an empty window') if manual_call? && !scoped_relation.exists?

      scoped_relation
    end
  end

  private

  attr_reader :threads_scope, :zone

  def normalize_fact_kind!
    @fact_kind = params[:fact_kind].to_s
    raise_invalid!('fact_kind is required') if fact_kind.blank?
    raise_invalid!('fact_kind is invalid') unless FACT_KINDS.include?(fact_kind)
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

  def normalize_as_of!
    if immutable_fact?
      date = parse_date!(:as_of_date)
      raise_invalid!('as_of_date must be on or after to_date') if date < (to_time.in_time_zone(timezone).to_date - 1.day)

      exclusive_date = date + 1.day
      @as_of_time = zone.local(exclusive_date.year, exclusive_date.month, exclusive_date.day)
    elsif params[:as_of_date].present?
      raise_invalid!("as_of_date is not supported for #{fact_kind} retained rows")
    end
  end

  def parse_date!(key)
    value = params[key]
    raise_invalid!("#{key} is required") if value.blank?
    raise_invalid!("#{key} must use YYYY-MM-DD") unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.iso8601(value.to_s)
  rescue Date::Error
    raise_invalid!("#{key} must be a valid date")
  end

  def validate_zone!
    raise_invalid!('workspace timezone is invalid') if zone.blank?
  end

  def adapter # rubocop:disable Metrics/MethodLength
    @adapter ||= if participant_lifecycle?
                   CommunicationThreads::CollaborationOccurrences::ParticipantLifecycleAdapter.new(
                     account: account,
                     threads_scope: threads_scope,
                     from_time: from_time,
                     to_time: to_time,
                     as_of_time: as_of_time
                   )
                 elsif manual_call?
                   CommunicationThreads::CollaborationOccurrences::ManualCallAdapter.new(
                     account: account,
                     threads_scope: threads_scope,
                     from_time: from_time,
                     to_time: to_time,
                     as_of_time: as_of_time
                   )
                 else
                   CommunicationThreads::CollaborationOccurrences::MessageAdapter.new(
                     account: account,
                     threads_scope: threads_scope,
                     from_time: from_time,
                     to_time: to_time,
                     fact_kind: fact_kind
                   )
                 end
  end

  def participant_lifecycle?
    fact_kind == 'participant_lifecycle'
  end

  def manual_call?
    fact_kind == 'manual_call'
  end

  def immutable_fact?
    participant_lifecycle? || manual_call?
  end

  def grouped_counts
    relation.group(:fact_kind, :source, :reliability, :actor_kind, :actor_type, :actor_id, :action)
            .order(:fact_kind, :source, :actor_kind, :actor_type, Arel.sql('actor_id ASC NULLS FIRST'), Arel.sql('action ASC NULLS FIRST'))
            .pluck(
              :fact_kind, :source, :reliability, :actor_kind, :actor_type, :actor_id, :action,
              Arel.sql('COUNT(*)'), Arel.sql('COUNT(DISTINCT communication_thread_id)'),
              Arel.sql('COUNT(*) FILTER (WHERE deleted)')
            )
  end

  def paginated_relation
    relation.order(occurred_at: :desc, occurrence_id: :desc).offset((page - 1) * per_page).limit(per_page)
  end

  def actor_payload(kind, type, id, name = nil)
    payload = {
      kind: kind,
      type: type,
      id: id,
      identity_state: id.present? ? 'persisted_raw_identity' : identity_state_without_id(kind)
    }
    payload[:name_snapshot] = name if name.present?
    payload
  end

  def identity_state_without_id(kind)
    kind == 'system' ? 'system' : 'unknown_deleted_or_missing_identity'
  end

  def action_actor_payload(occurrence)
    return if occurrence.action_actor_kind.blank?

    actor_payload(occurrence.action_actor_kind, occurrence.action_actor_type, occurrence.action_actor_id)
  end

  def source_catalog
    [adapter.metadata, manual_call_metadata].uniq { |source| source[:fact_kind] }
  end

  def manual_call_metadata
    CommunicationThreads::CollaborationOccurrences::ManualCallAdapter.metadata
  end

  def window_metadata
    {
      timezone: timezone,
      from: from_time.utc.iso8601(6),
      to: to_time.utc.iso8601(6),
      from_local: from_time.iso8601(6),
      to_local: to_time.iso8601(6),
      as_of: as_of_time&.utc&.iso8601(6),
      as_of_local: as_of_time&.iso8601(6)
    }
  end

  def page
    @page ||= parse_positive_integer!(:page, default: 1, max: MAX_PAGE)
  end

  def per_page
    @per_page ||= parse_positive_integer!(:per_page, default: DEFAULT_PER_PAGE, max: MAX_PER_PAGE)
  end

  def parse_positive_integer!(key, default:, max: nil)
    value = params[key].presence || default
    raise_invalid!("#{key} must be a positive integer") unless value.to_s.match?(/\A[1-9]\d*\z/)

    parsed = value.to_i
    raise_invalid!("#{key} must not exceed #{max}") if max && parsed > max
    parsed
  end

  def query_fingerprint
    @query_fingerprint ||= Digest::SHA256.hexdigest(
      [QUERY_KIND, account.id, threads_scope.to_sql, fact_kind, from_time.utc.iso8601(6), to_time.utc.iso8601(6),
       as_of_time&.utc&.iso8601(6)].to_json
    )
  end

  def raise_invalid!(message)
    raise InvalidQuery, message
  end
end
