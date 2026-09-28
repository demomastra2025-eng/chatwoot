class AddCaptainControlToCommunicationThreads < ActiveRecord::Migration[7.1]
  def up
    add_control_columns
    backfill_control_state
  end

  def down
    remove_column :communication_threads, :captain_handoff_applied_at if column_exists?(
      :communication_threads, :captain_handoff_applied_at
    )
    remove_column :communication_threads, :captain_control_generation if column_exists?(
      :communication_threads, :captain_control_generation
    )
    remove_column :communication_threads, :captain_control_state if column_exists?(
      :communication_threads, :captain_control_state
    )
  end

  private

  def add_control_columns
    add_control_state_column
    add_control_generation_column
    add_handoff_applied_at_column
  end

  def add_control_state_column
    return if column_exists?(:communication_threads, :captain_control_state)

    add_column :communication_threads, :captain_control_state, :string, null: false, default: 'ai'
  end

  def add_control_generation_column
    return if column_exists?(:communication_threads, :captain_control_generation)

    add_column :communication_threads, :captain_control_generation, :bigint, null: false, default: 0
  end

  def add_handoff_applied_at_column
    return if column_exists?(:communication_threads, :captain_handoff_applied_at)

    add_column :communication_threads, :captain_handoff_applied_at, :datetime
  end

  def backfill_control_state
    # Invalidate every pre-migration Captain run while preserving the strongest
    # control state already recorded by any conversation in the thread.
    execute <<~SQL.squish
      UPDATE communication_threads
      SET captain_control_state = aggregates.control_state,
          captain_control_generation = aggregates.control_generation,
          captain_handoff_applied_at = aggregates.handoff_applied_at
      FROM (
        SELECT communication_thread_conversations.communication_thread_id,
               CASE WHEN BOOL_OR(captain_control_state = 'human') THEN 'human' ELSE 'ai' END AS control_state,
               MAX(captain_control_generation) + 1 AS control_generation,
               MAX(captain_handoff_applied_at) AS handoff_applied_at
        FROM communication_thread_conversations
        INNER JOIN conversations ON conversations.id = communication_thread_conversations.conversation_id
        GROUP BY communication_thread_conversations.communication_thread_id
      ) aggregates
      WHERE communication_threads.id = aggregates.communication_thread_id
    SQL
  end
end
