class EnsureCaptainTakeoverControlColumns < ActiveRecord::Migration[7.1]
  def up
    %i[conversations communication_threads].each do |table|
      add_column table, :captain_control_state, :string, null: false, default: 'ai' unless column_exists?(table, :captain_control_state)
      add_column table, :captain_control_generation, :bigint, null: false, default: 0 unless column_exists?(table, :captain_control_generation)
      add_column table, :captain_handoff_applied_at, :datetime unless column_exists?(table, :captain_handoff_applied_at)
    end

    # A thread is the sole control owner once its channels are linked. Preserve
    # an existing human takeover while invalidating jobs queued before the bridge.
    execute <<~SQL.squish
      UPDATE communication_threads
      SET captain_control_state = CASE WHEN communication_threads.captain_control_state = 'human' OR aggregates.control_state = 'human'
                                       THEN 'human' ELSE 'ai' END,
          captain_control_generation = GREATEST(communication_threads.captain_control_generation, aggregates.control_generation) + 1,
          captain_handoff_applied_at = GREATEST(communication_threads.captain_handoff_applied_at, aggregates.handoff_applied_at)
      FROM (
        SELECT links.communication_thread_id,
               CASE WHEN BOOL_OR(conversations.captain_control_state = 'human') THEN 'human' ELSE 'ai' END AS control_state,
               MAX(conversations.captain_control_generation) AS control_generation,
               MAX(conversations.captain_handoff_applied_at) AS handoff_applied_at
        FROM communication_thread_conversations links
        JOIN conversations ON conversations.id = links.conversation_id
        GROUP BY links.communication_thread_id
      ) aggregates
      WHERE communication_threads.id = aggregates.communication_thread_id
        AND (communication_threads.captain_control_generation = 0 OR
             (aggregates.control_state = 'human' AND communication_threads.captain_control_state <> 'human'))
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Captain control columns may be shared with the selective RC'
  end
end
