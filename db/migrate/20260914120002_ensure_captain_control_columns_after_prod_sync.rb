class EnsureCaptainControlColumnsAfterProdSync < ActiveRecord::Migration[7.1]
  def up
    # The conversation migration shared a version with aset's participant
    # migration. An aset database may have skipped the Captain columns at 20260914120000.
    raise 'conversations table is required' unless table_exists?(:conversations)

    unless column_exists?(:conversations, :captain_control_state)
      add_column :conversations, :captain_control_state, :string, default: 'ai', null: false
    end
    unless column_exists?(:conversations, :captain_control_generation)
      add_column :conversations, :captain_control_generation, :bigint, default: 0, null: false
    end
    add_column :conversations, :captain_handoff_applied_at, :datetime unless column_exists?(:conversations, :captain_handoff_applied_at)
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'These columns may predate the bridge on PROD-derived databases'
  end
end
