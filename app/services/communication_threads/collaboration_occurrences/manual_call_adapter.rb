class CommunicationThreads::CollaborationOccurrences::ManualCallAdapter
  SOURCE = 'communication_thread_manual_call_occurrences'.freeze
  FACT_KIND = 'manual_call'.freeze

  attr_reader :account, :threads_scope, :from_time, :to_time, :as_of_time

  def initialize(account:, threads_scope:, from_time:, to_time:, as_of_time:)
    @account = account
    @threads_scope = threads_scope
    @from_time = from_time
    @to_time = to_time
    @as_of_time = as_of_time
  end

  def relation
    CommunicationThreadManualCallOccurrence.unscoped
                                           .from("(#{occurrences_sql}) collaboration_occurrences")
                                           .select('collaboration_occurrences.*')
  end

  def metadata
    self.class.metadata
  end

  def self.metadata
    {
      fact_kind: FACT_KIND,
      source: SOURCE,
      availability: 'available_recorded_occurrences_only',
      reliability: 'exact_immutable_occurrence',
      retention: 'append_only_except_account_teardown',
      as_of_supported: true,
      temporal_definition: 'occurred_at_in_workspace_half_open_window_and_created_before_as_of',
      actor_definition: 'authenticated_manual_call_initiator_snapshot_not_thread_owner_call_operator_or_ai_agent',
      coverage_definition: 'durably_recorded_native_manual_call_occurrences_only_not_complete_call_history',
      zero_definition: 'unknown_empty_windows_are_rejected_without_a_source_coverage_watermark',
      backfill: 'none_unrecorded_history_is_unknown',
      limitations: 'legacy_provider_calls_without_a_telephony_call_session_and_inbound_or_ai_voice_calls_are_excluded'
    }
  end

  private

  def occurrences_sql # rubocop:disable Metrics/MethodLength
    <<~SQL.squish
      SELECT
        occurrences.id AS occurrence_id,
        occurrences.communication_thread_id,
        occurrences.occurred_at,
        #{quote(FACT_KIND)} AS fact_kind,
        #{quote(SOURCE)} AS source,
        'exact_immutable_occurrence' AS reliability,
        'append_only_except_account_teardown' AS retention,
        'user' AS actor_kind,
        occurrences.actor_type,
        occurrences.actor_id,
        occurrences.actor_name,
        NULL::varchar AS action,
        NULL::varchar AS action_actor_kind,
        NULL::varchar AS action_actor_type,
        NULL::bigint AS action_actor_id,
        FALSE AS deleted,
        occurrences.schema_version,
        occurrences.reliable_since,
        occurrences.source_kind || ':' || occurrences.source_id::text AS correlation_id
      FROM communication_thread_manual_call_occurrences occurrences
      INNER JOIN (#{visible_threads_sql}) visible_threads
        ON visible_threads.id = occurrences.communication_thread_id
      WHERE occurrences.account_id = #{quote(account.id)}
        AND occurrences.occurred_at >= #{quote(from_time.utc)}
        AND occurrences.occurred_at < #{quote(to_time.utc)}
        AND occurrences.created_at < #{quote(as_of_time.utc)}
    SQL
  end

  def visible_threads_sql
    threads_scope.where(account_id: account.id).reselect(:id).reorder(nil).to_sql
  end

  def quote(value)
    ActiveRecord::Base.connection.quote(value)
  end
end
