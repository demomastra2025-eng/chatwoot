class AddPendingCaptainOutcomeIndex < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :conversation_status_transitions, [:updated_at, :id],
              name: 'idx_pending_captain_outcome_classification',
              where: "metadata->'outcome_classification'->>'state' IN ('pending', 'processing')",
              algorithm: :concurrently, if_not_exists: true
  end
end
