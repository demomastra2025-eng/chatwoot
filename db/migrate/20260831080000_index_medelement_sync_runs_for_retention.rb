class IndexMedelementSyncRunsForRetention < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :medelement_sync_runs,
              :completed_at,
              where: "status IN ('succeeded', 'partial', 'failed')",
              algorithm: :concurrently,
              name: 'idx_medelement_sync_runs_terminal_completed'
  end
end
