class AddNativeLifecycleFieldsToTelephonyCallSessions < ActiveRecord::Migration[7.0]
  def up
    add_column :telephony_call_sessions, :answered_at, :datetime unless column_exists?(:telephony_call_sessions, :answered_at)
    add_column :telephony_call_sessions, :answered_by, :string unless column_exists?(:telephony_call_sessions, :answered_by)
    add_column :telephony_call_sessions, :ended_by, :string unless column_exists?(:telephony_call_sessions, :ended_by)
    add_column :telephony_call_sessions, :end_reason, :string unless column_exists?(:telephony_call_sessions, :end_reason)
    add_column :telephony_call_sessions, :legs, :jsonb, null: false, default: [] unless column_exists?(:telephony_call_sessions, :legs)

    execute <<~SQL.squish
      UPDATE telephony_call_sessions
      SET status = CASE status
        WHEN 'in-progress' THEN 'in_progress'
        WHEN 'no-answer' THEN 'no_answer'
        WHEN 'canceled' THEN 'cancelled'
        WHEN 'queued' THEN 'created'
        ELSE status
      END
      WHERE status IN ('in-progress', 'no-answer', 'canceled', 'queued')
    SQL
  end

  def down
    execute <<~SQL.squish
      UPDATE telephony_call_sessions
      SET status = CASE status
        WHEN 'in_progress' THEN 'in-progress'
        WHEN 'no_answer' THEN 'no-answer'
        WHEN 'cancelled' THEN 'canceled'
        WHEN 'created' THEN 'queued'
        ELSE status
      END
      WHERE status IN ('in_progress', 'no_answer', 'cancelled', 'created')
    SQL

    remove_column :telephony_call_sessions, :legs if column_exists?(:telephony_call_sessions, :legs)
    remove_column :telephony_call_sessions, :end_reason if column_exists?(:telephony_call_sessions, :end_reason)
    remove_column :telephony_call_sessions, :ended_by if column_exists?(:telephony_call_sessions, :ended_by)
    remove_column :telephony_call_sessions, :answered_by if column_exists?(:telephony_call_sessions, :answered_by)
    remove_column :telephony_call_sessions, :answered_at if column_exists?(:telephony_call_sessions, :answered_at)
  end
end
