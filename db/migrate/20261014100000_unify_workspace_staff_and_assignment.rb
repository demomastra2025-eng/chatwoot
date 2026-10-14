class UnifyWorkspaceStaffAndAssignment < ActiveRecord::Migration[7.2]
  def up
    backfill_memberships
    backfill_auto_assignment
    backfill_policy
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Workspace membership and settings preserve existing data'
  end

  private

  def backfill_memberships
    execute <<~SQL.squish
      INSERT INTO inbox_members (inbox_id, user_id, created_at, updated_at)
      SELECT i.id, au.user_id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM inboxes i
      JOIN account_users au ON au.account_id = i.account_id
      ON CONFLICT (inbox_id, user_id) DO NOTHING
    SQL
  end

  def backfill_auto_assignment
    execute <<~SQL.squish
      WITH workspace_votes AS (
        SELECT account_id,
               COUNT(*) FILTER (WHERE enable_auto_assignment = TRUE) AS enabled_count,
               COUNT(*) FILTER (WHERE enable_auto_assignment = FALSE) AS disabled_count
        FROM inboxes GROUP BY account_id
      )
      UPDATE accounts a
      SET settings = jsonb_set(COALESCE(a.settings, '{}'::jsonb),
                               '{conversation_auto_assignment_enabled}',
                               to_jsonb(v.enabled_count >= v.disabled_count))
      FROM workspace_votes v
      WHERE a.id = v.account_id
        AND NOT COALESCE(a.settings, '{}'::jsonb) ? 'conversation_auto_assignment_enabled'
    SQL
  end

  def backfill_policy
    execute <<~SQL.squish
      WITH linked_policies AS (
        SELECT i.account_id, MIN(iap.assignment_policy_id) AS policy_id
        FROM inbox_assignment_policies iap
        JOIN inboxes i ON i.id = iap.inbox_id
        JOIN assignment_policies p ON p.id = iap.assignment_policy_id AND p.account_id = i.account_id
        GROUP BY i.account_id
      )
      UPDATE accounts a
      SET settings = jsonb_set(COALESCE(a.settings, '{}'::jsonb),
                               '{conversation_assignment_policy_id}', to_jsonb(lp.policy_id))
      FROM linked_policies lp
      WHERE a.id = lp.account_id
        AND NOT COALESCE(a.settings, '{}'::jsonb) ? 'conversation_assignment_policy_id'
    SQL
  end
end
