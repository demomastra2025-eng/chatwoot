class CommunicationThreads::CollaborationOccurrences::ParticipantLifecycleAdapter
  SOURCE = 'communication_thread_participant_lifecycle_facts'.freeze
  FACT_KIND = 'participant_lifecycle'.freeze

  attr_reader :account, :threads_scope, :from_time, :to_time, :as_of_time

  def initialize(account:, threads_scope:, from_time:, to_time:, as_of_time:)
    @account = account
    @threads_scope = threads_scope
    @from_time = from_time
    @to_time = to_time
    @as_of_time = as_of_time
  end

  def relation
    CommunicationThreadParticipantLifecycleFact.unscoped
                                               .from("(#{occurrences_sql}) collaboration_occurrences")
                                               .select('collaboration_occurrences.*')
  end

  def metadata
    {
      fact_kind: FACT_KIND,
      source: SOURCE,
      availability: 'available',
      reliability: 'exact_immutable_occurrence',
      retention: 'append_only_except_account_teardown',
      as_of_supported: true,
      temporal_definition: 'occurred_at_in_workspace_half_open_window_and_created_before_as_of',
      actor_definition: 'participant_is_collaboration_subject_action_actor_is_separate_persisted_identity',
      limitations: 'membership_intervals_are_not_inferred_from_occurrences'
    }
  end

  private

  def occurrences_sql # rubocop:disable Metrics/MethodLength
    <<~SQL.squish
      SELECT
        facts.id AS occurrence_id,
        facts.communication_thread_id,
        facts.occurred_at,
        #{quote(FACT_KIND)} AS fact_kind,
        #{quote(SOURCE)} AS source,
        'exact_immutable_occurrence' AS reliability,
        'append_only_except_account_teardown' AS retention,
        'user' AS actor_kind,
        facts.participant_type AS actor_type,
        facts.participant_id AS actor_id,
        NULL::varchar AS actor_name,
        facts.action,
        facts.actor_kind AS action_actor_kind,
        facts.actor_type AS action_actor_type,
        facts.actor_id AS action_actor_id,
        FALSE AS deleted,
        facts.schema_version,
        facts.reliable_since,
        facts.correlation_id::text AS correlation_id
      FROM communication_thread_participant_lifecycle_facts facts
      INNER JOIN (#{visible_threads_sql}) visible_threads
        ON visible_threads.id = facts.communication_thread_id
      WHERE facts.account_id = #{quote(account.id)}
        AND facts.occurred_at >= #{quote(from_time.utc)}
        AND facts.occurred_at < #{quote(to_time.utc)}
        AND facts.created_at < #{quote(as_of_time.utc)}
    SQL
  end

  def visible_threads_sql
    threads_scope.where(account_id: account.id).reselect(:id).reorder(nil).to_sql
  end

  def quote(value)
    ActiveRecord::Base.connection.quote(value)
  end
end
