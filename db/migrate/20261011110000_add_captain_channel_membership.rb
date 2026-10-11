# frozen_string_literal: true

class AddCaptainChannelMembership < ActiveRecord::Migration[7.2]
  def up
    add_column :captain_assistants, :channel_scope, :string, null: false, default: 'all'
    add_check_constraint :captain_assistants, "channel_scope IN ('all', 'selected')", name: 'captain_assistants_channel_scope'
    add_column :captain_inboxes, :ai_enabled, :boolean, null: false, default: false

    create_table :captain_agent_channels do |t|
      t.bigint :account_id, null: false
      t.bigint :assistant_id, null: false
      t.bigint :inbox_id, null: false
      t.timestamps
    end
    add_index :captain_agent_channels, [:assistant_id, :inbox_id], unique: true
    add_index :captain_agent_channels, :inbox_id
    add_index :captain_agent_channels, :account_id
    add_foreign_key :captain_agent_channels, :accounts
    add_foreign_key :captain_agent_channels, :captain_assistants, column: [:assistant_id, :account_id],
                    primary_key: [:id, :account_id], on_delete: :cascade
    add_foreign_key :captain_agent_channels, :inboxes, column: :inbox_id, on_delete: :cascade

    backfill_membership!
    execute('UPDATE captain_inboxes SET ai_enabled = TRUE WHERE ai_enabled = FALSE')
    execute("UPDATE captain_assistants SET channel_scope = 'selected' WHERE usage_mode = 'external_agent'")

    duplicate_ids = select_values('SELECT inbox_id FROM captain_inboxes GROUP BY inbox_id HAVING COUNT(*) > 1 ORDER BY inbox_id')
    if duplicate_ids.empty?
      add_index :captain_inboxes, :inbox_id, unique: true, name: 'index_captain_inboxes_on_unique_inbox_id'
    else
      say "Captain inbox duplicate inbox ids: #{duplicate_ids.join(', ')}"
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Captain channel membership preserves existing routing data'
  end

  # The recursive walk mirrors AgentGraph: entry plus active external targets,
  # including transitive edges. Conflict handling makes this safe to rerun.
  def backfill_membership!
    execute <<~SQL.squish
      WITH RECURSIVE reachable(inbox_id, account_id, assistant_id) AS (
        SELECT ci.inbox_id, a.account_id, a.id
        FROM captain_inboxes ci
        JOIN captain_assistants a ON a.id = ci.captain_assistant_id
        JOIN inboxes i ON i.id = ci.inbox_id AND i.account_id = a.account_id
        WHERE a.active = TRUE AND a.usage_mode = 'external_agent'
          AND i.channel_type IS DISTINCT FROM 'Channel::Voice'
        UNION
        SELECT r.inbox_id, r.account_id, target.id
        FROM reachable r
        JOIN captain_agent_handoffs h ON h.source_assistant_id = r.assistant_id AND h.account_id = r.account_id
        JOIN captain_assistants target ON target.id = h.target_assistant_id AND target.account_id = r.account_id
        WHERE target.active = TRUE AND target.usage_mode = 'external_agent'
      )
      INSERT INTO captain_agent_channels (account_id, assistant_id, inbox_id, created_at, updated_at)
      SELECT account_id, assistant_id, inbox_id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM reachable
      ON CONFLICT (assistant_id, inbox_id) DO NOTHING
    SQL
  end
end
