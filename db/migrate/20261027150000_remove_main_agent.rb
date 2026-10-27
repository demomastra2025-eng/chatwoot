# Removes the «main agent»: every agent of a workspace is a peer with the same on/off switch, and a text channel names no agent.
# The old values are copied to captain_main_agent_backups first, so that `down` restores them. Voice numbers keep their agent.
# captain_assistants.channel_scope, captain_agent_channels and captain_agent_handoffs are left in place (nothing reads them any more).
class RemoveMainAgent < ActiveRecord::Migration[7.2]
  ACCOUNT_DEFAULT = 'account_default'.freeze
  TEXT_INBOX_AGENT = 'text_inbox_agent'.freeze

  def up
    create_table :captain_main_agent_backups do |t|
      t.string :kind, null: false
      t.bigint :account_id, null: false
      t.bigint :inbox_id
      t.bigint :assistant_id, null: false
      t.datetime :created_at, null: false
      t.index %i[kind account_id inbox_id], name: 'index_captain_main_agent_backups_on_kind_account_inbox'
    end

    backup_account_defaults
    backup_text_inbox_agents
    change_column_null :captain_inboxes, :captain_assistant_id, true
    execute <<~SQL.squish
      UPDATE captain_inboxes SET captain_assistant_id = NULL
      WHERE inbox_id IN (SELECT id FROM inboxes WHERE channel_type <> 'Channel::Voice')
    SQL
    execute "UPDATE accounts SET settings = settings - 'captain_default_assistant_id' WHERE settings ? 'captain_default_assistant_id'"
  end

  def down
    restore_account_defaults
    restore_text_inbox_agents
    give_agent_to_text_rows_without_backup
    change_column_null :captain_inboxes, :captain_assistant_id, false
    drop_table :captain_main_agent_backups
  end

  private

  # An account whose default is a number. A default that was null or junk has nothing to restore.
  def backup_account_defaults
    execute <<~SQL.squish
      INSERT INTO captain_main_agent_backups (kind, account_id, inbox_id, assistant_id, created_at)
      SELECT '#{ACCOUNT_DEFAULT}', id, NULL, (settings ->> 'captain_default_assistant_id')::bigint, NOW()
      FROM accounts
      WHERE settings ->> 'captain_default_assistant_id' ~ '^[0-9]+$'
    SQL
  end

  def backup_text_inbox_agents
    execute <<~SQL.squish
      INSERT INTO captain_main_agent_backups (kind, account_id, inbox_id, assistant_id, created_at)
      SELECT '#{TEXT_INBOX_AGENT}', i.account_id, i.id, ci.captain_assistant_id, NOW()
      FROM captain_inboxes ci JOIN inboxes i ON i.id = ci.inbox_id
      WHERE i.channel_type <> 'Channel::Voice' AND ci.captain_assistant_id IS NOT NULL
    SQL
  end

  # The saved default comes back while that agent is still an enabled external agent (the old rules required it); otherwise the
  # lowest-id enabled external agent of the account takes its place, and an account without one has no default.
  def restore_account_defaults
    execute <<~SQL.squish
      UPDATE accounts a
      SET settings = jsonb_set(COALESCE(a.settings, '{}'::jsonb), '{captain_default_assistant_id}', to_jsonb(restored.assistant_id))
      FROM (
        SELECT b.account_id,
               COALESCE(
                 (SELECT s.id FROM captain_assistants s WHERE s.id = b.assistant_id AND s.account_id = b.account_id
                    AND s.active = TRUE AND s.usage_mode = 'external_agent'),
                 (SELECT MIN(s.id) FROM captain_assistants s WHERE s.account_id = b.account_id
                    AND s.active = TRUE AND s.usage_mode = 'external_agent')
               ) AS assistant_id
        FROM captain_main_agent_backups b WHERE b.kind = '#{ACCOUNT_DEFAULT}'
      ) restored
      WHERE restored.account_id = a.id AND restored.assistant_id IS NOT NULL
    SQL
  end

  # The agent of a text row comes back by inbox when that agent still exists.
  def restore_text_inbox_agents
    execute <<~SQL.squish
      UPDATE captain_inboxes ci
      SET captain_assistant_id = b.assistant_id
      FROM captain_main_agent_backups b
      JOIN captain_assistants s ON s.id = b.assistant_id AND s.account_id = b.account_id
      WHERE b.kind = '#{TEXT_INBOX_AGENT}' AND b.inbox_id = ci.inbox_id AND ci.captain_assistant_id IS NULL
    SQL
  end

  # A text row made after `up` has no backup: it takes the account default, else the lowest-id enabled external agent, else the row
  # goes (the AI could not answer on it anyway).
  def give_agent_to_text_rows_without_backup
    execute <<~SQL.squish
      UPDATE captain_inboxes ci
      SET captain_assistant_id = COALESCE(
        (SELECT s.id FROM captain_assistants s WHERE s.account_id = i.account_id AND s.active = TRUE
           AND s.usage_mode = 'external_agent'
           AND s.id = CASE WHEN a.settings ->> 'captain_default_assistant_id' ~ '^[0-9]+$'
                           THEN (a.settings ->> 'captain_default_assistant_id')::bigint END),
        (SELECT MIN(s.id) FROM captain_assistants s WHERE s.account_id = i.account_id AND s.active = TRUE AND s.usage_mode = 'external_agent')
      )
      FROM inboxes i JOIN accounts a ON a.id = i.account_id
      WHERE i.id = ci.inbox_id AND ci.captain_assistant_id IS NULL
    SQL
    execute 'DELETE FROM captain_inboxes WHERE captain_assistant_id IS NULL'
  end
end
