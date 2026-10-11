# frozen_string_literal: true

class Reports::AiAgentEventsQuery
  CLASSIFICATION_STATES = %w[completed pending processing failed insufficient_context unclassified].freeze

  # One statement keeps event totals and reason counts in the same database snapshot.
  # Each native event supplies its own date; conversation creation is not a cohort filter.
  SQL = <<~SQL.freeze
    WITH message_events AS (
      SELECT messages.sender_id AS assistant_id, messages.conversation_id,
             ((messages.created_at AT TIME ZONE 'UTC') AT TIME ZONE :timezone)::date AS event_date,
             messages.created_at AS event_time, messages.id AS event_id, 'message'::text AS event_type,
             NULL::text AS classification_state, NULL::text AS reason_id, NULL::text AS reason_label
      FROM messages
      JOIN conversations ON conversations.id = messages.conversation_id AND conversations.account_id = :account_id
      LEFT JOIN captain_assistants AS authors ON authors.id = messages.sender_id
      WHERE messages.account_id = :account_id AND messages.sender_type = 'Captain::Assistant'
        AND NOT (conversations.additional_attributes ? 'captain_playground_source')
        AND NOT (conversations.additional_attributes ? 'captain_benchmark_source')
        AND messages.sender_id IS NOT NULL AND messages.message_type = :outgoing_type AND messages.private = FALSE
        AND messages.created_at >= :from_at AND messages.created_at < :until_at
        AND (authors.id IS NULL OR authors.account_id = :account_id)
        AND (:assistant_id IS NULL OR messages.sender_id = :assistant_id)
    ), outcome_events AS (
      SELECT transitions.actor_id AS assistant_id, transitions.conversation_id,
             ((transitions.created_at AT TIME ZONE 'UTC') AT TIME ZONE :timezone)::date AS event_date,
             transitions.created_at AS event_time, transitions.id AS event_id,
             CASE WHEN transitions.to_status = 'resolved' THEN 'completion' ELSE 'handoff' END AS event_type,
             CASE WHEN transitions.metadata #>> '{outcome_classification,state}' IN
                            ('completed', 'pending', 'processing', 'failed', 'insufficient_context')
                  THEN transitions.metadata #>> '{outcome_classification,state}' ELSE 'unclassified' END AS classification_state,
             NULLIF(BTRIM(transitions.metadata ->> 'outcome_reason_id'), '') AS reason_id,
             COALESCE(
               (SELECT reason_item ->> 'label'
                FROM jsonb_array_elements(CASE
                  WHEN jsonb_typeof(transitions.metadata #> '{outcome_classification,reasons}') = 'array'
                  THEN transitions.metadata #> '{outcome_classification,reasons}' ELSE '[]'::jsonb END) AS reason_item
                WHERE reason_item ->> 'id' = transitions.metadata ->> 'outcome_reason_id' LIMIT 1),
               NULLIF(transitions.reason, ''), transitions.metadata ->> 'outcome_reason_id'
             ) AS reason_label
      FROM conversation_status_transitions AS transitions
      JOIN conversations ON conversations.id = transitions.conversation_id AND conversations.account_id = :account_id
      LEFT JOIN captain_assistants AS actors ON actors.id = transitions.actor_id
      WHERE transitions.account_id = :account_id AND transitions.actor_type = 'Captain::Assistant'
        AND NOT (conversations.additional_attributes ? 'captain_playground_source')
        AND NOT (conversations.additional_attributes ? 'captain_benchmark_source')
        AND transitions.actor_id IS NOT NULL AND transitions.source IN ('captain', 'system')
        AND transitions.to_status IN ('open', 'resolved') AND transitions.from_status <> transitions.to_status
        AND transitions.created_at >= :from_at AND transitions.created_at < :until_at
        AND (actors.id IS NULL OR actors.account_id = :account_id)
        AND (:assistant_id IS NULL OR transitions.actor_id = :assistant_id)
    ), events AS (
      SELECT * FROM message_events UNION ALL SELECT * FROM outcome_events
    ), metrics AS (
      SELECT CASE WHEN GROUPING(event_date) = 0 THEN 'series'
                  WHEN GROUPING(assistant_id) = 0 THEN 'agent' ELSE 'total' END AS row_type,
             assistant_id, event_date AS date,
             COUNT(*) FILTER (WHERE event_type = 'message') AS message_count,
             COUNT(DISTINCT conversation_id) AS conversation_count,
             COUNT(*) FILTER (WHERE event_type <> 'message') AS outcome_count,
             COUNT(*) FILTER (WHERE event_type = 'completion') AS completion_count,
             COUNT(*) FILTER (WHERE event_type = 'handoff') AS handoff_count,
             jsonb_build_object(
               'completed', COUNT(*) FILTER (WHERE classification_state = 'completed'),
               'pending', COUNT(*) FILTER (WHERE classification_state = 'pending'),
               'processing', COUNT(*) FILTER (WHERE classification_state = 'processing'),
               'failed', COUNT(*) FILTER (WHERE classification_state = 'failed'),
               'insufficient_context', COUNT(*) FILTER (WHERE classification_state = 'insufficient_context'),
               'unclassified', COUNT(*) FILTER (WHERE classification_state = 'unclassified')
             ) AS classification_counts
      FROM events GROUP BY GROUPING SETS ((), (event_date), (assistant_id))
    ), reason_rows AS (
      SELECT DISTINCT ON (assistant_id, event_type, reason_id)
             assistant_id, event_type AS type, reason_id, reason_label AS label,
             COUNT(*) OVER (PARTITION BY assistant_id, event_type, reason_id) AS count
      FROM events
      WHERE classification_state = 'completed' AND reason_id IS NOT NULL
      ORDER BY assistant_id, event_type, reason_id, event_time DESC, event_id DESC
    )
    SELECT 'metric' AS kind, to_jsonb(metrics) || jsonb_build_object('name', agents.name, 'active', agents.active) AS data
    FROM metrics
    LEFT JOIN captain_assistants AS agents ON agents.id = metrics.assistant_id AND agents.account_id = :account_id
    UNION ALL
    SELECT 'reason' AS kind, to_jsonb(reason_rows) AS data FROM reason_rows
  SQL

  def initialize(account:, date_range:, assistant_id: nil)
    @account = account
    @date_range = date_range
    @assistant_id = assistant_id
  end

  def perform
    sql = ActiveRecord::Base.sanitize_sql_array([SQL, bindings])
    ActiveRecord::Base.connection.select_all(sql, 'AI agents report').map do |row|
      data = row['data'].is_a?(String) ? JSON.parse(row['data']) : row['data']
      { kind: row['kind'], data: data.symbolize_keys }
    end
  end

  private

  def bindings
    {
      account_id: @account.id, assistant_id: @assistant_id,
      timezone: @date_range.timezone.tzinfo.name,
      from_at: @date_range.from_at, until_at: @date_range.until_at,
      outgoing_type: Message.message_types.fetch('outgoing')
    }
  end
end
