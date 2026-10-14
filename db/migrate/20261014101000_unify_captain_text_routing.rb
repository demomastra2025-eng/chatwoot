class UnifyCaptainTextRouting < ActiveRecord::Migration[7.2]
  def up
    # Count distinct handled conversations, never message contents.
    execute <<~SQL.squish
      #{candidate_query}, migrated AS (
        #{migrate_accounts_query}
      )
      UPDATE captain_inboxes ci
      SET captain_assistant_id = COALESCE((migrated.settings ->> 'captain_default_assistant_id')::bigint,
                                          ci.captain_assistant_id),
          ai_enabled = TRUE
      FROM inboxes i JOIN migrated ON migrated.id = i.account_id
      WHERE ci.inbox_id = i.id AND i.channel_type <> 'Channel::Voice'
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Original text routing links remain stored but cannot be inferred after new routing'
  end

  private

  def linked_agents_query
    <<~SQL.squish
      WITH linked_agents AS (
        SELECT DISTINCT i.account_id, ci.captain_assistant_id
        FROM captain_inboxes ci JOIN inboxes i ON i.id = ci.inbox_id
        WHERE i.channel_type <> 'Channel::Voice'
      )
    SQL
  end

  def candidate_query
    <<~SQL.squish
      #{linked_agents_query}, link_counts AS (
        SELECT account_id, COUNT(*) AS agent_count FROM linked_agents GROUP BY account_id
      ), candidates AS (
        SELECT a.account_id, a.id,
               ROW_NUMBER() OVER (
                 PARTITION BY a.account_id
                 ORDER BY COUNT(DISTINCT m.conversation_id) DESC, a.created_at ASC, a.id ASC
               ) AS position
        FROM captain_assistants a
        LEFT JOIN messages m ON m.account_id = a.account_id
          AND m.sender_type = 'Captain::Assistant' AND m.sender_id = a.id
        WHERE a.active = TRUE AND a.usage_mode = 'external_agent'
          AND (
            NOT EXISTS (SELECT 1 FROM link_counts lc WHERE lc.account_id = a.account_id)
            OR EXISTS (SELECT 1 FROM linked_agents la WHERE la.account_id = a.account_id AND la.captain_assistant_id = a.id)
          )
        GROUP BY a.account_id, a.id, a.created_at
      )
    SQL
  end

  def migrate_accounts_query
    <<~SQL.squish
      UPDATE accounts account
      SET settings = jsonb_set(
        jsonb_set(COALESCE(account.settings, '{}'::jsonb), '{captain_default_assistant_id}',
          COALESCE(to_jsonb(CASE
            WHEN COALESCE(selected.agent_count, 0) > 1 OR NULLIF(account.settings ->> 'captain_default_assistant_id', '') IS NULL
            THEN selected.assistant_id
            ELSE (account.settings ->> 'captain_default_assistant_id')::bigint
          END), 'null'::jsonb)),
        '{captain_ai_routing_migrated}', 'true'::jsonb)
      FROM (SELECT a.id AS account_id, c.id AS assistant_id, lc.agent_count
        FROM accounts a
        LEFT JOIN candidates c ON c.account_id = a.id AND c.position = 1
        LEFT JOIN link_counts lc ON lc.account_id = a.id
      ) selected
      WHERE selected.account_id = account.id
        AND COALESCE(account.settings ->> 'captain_ai_routing_migrated', 'false') <> 'true'
      RETURNING account.id, account.settings
    SQL
  end
end
