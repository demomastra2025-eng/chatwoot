class RemoveFlowBuilderAgentBots < ActiveRecord::Migration[7.0]
  # rubocop:disable Metrics/MethodLength
  def up
    execute <<~SQL.squish
      UPDATE conversations
      SET assignee_agent_bot_id = NULL
      WHERE assignee_agent_bot_id IN (SELECT id FROM agent_bots WHERE bot_type = 1)
    SQL

    execute <<~SQL.squish
      UPDATE messages
      SET sender_id = NULL
      WHERE sender_type = 'AgentBot'
        AND sender_id IN (SELECT id FROM agent_bots WHERE bot_type = 1)
    SQL

    execute <<~SQL.squish
      DELETE FROM agent_bot_inboxes
      WHERE agent_bot_id IN (SELECT id FROM agent_bots WHERE bot_type = 1)
    SQL

    execute <<~SQL.squish
      DELETE FROM access_tokens
      WHERE owner_type = 'AgentBot'
        AND owner_id IN (SELECT id FROM agent_bots WHERE bot_type = 1)
    SQL

    execute <<~SQL.squish
      DELETE FROM platform_app_permissibles
      WHERE permissible_type = 'AgentBot'
        AND permissible_id IN (SELECT id FROM agent_bots WHERE bot_type = 1)
    SQL

    execute <<~SQL.squish
      DELETE FROM active_storage_attachments
      WHERE record_type = 'AgentBot'
        AND record_id IN (SELECT id FROM agent_bots WHERE bot_type = 1)
    SQL

    execute <<~SQL.squish
      DELETE FROM agent_bots
      WHERE bot_type = 1
    SQL
  end
  # rubocop:enable Metrics/MethodLength

  def down
    # Removed builder records cannot be restored safely.
  end
end
