class ConvertCsmlBotsToWebhookBots < ActiveRecord::Migration[7.0]
  def up
    # Find all CSML bots (bot_type = 1) and convert them to webhook (bot_type = 0).
    # Plain SQL: the AgentBot model was removed from the application, the table is still there.
    execute <<~SQL.squish
      UPDATE agent_bots
      SET bot_type = 0, bot_config = '{}'
      WHERE bot_type = 1
    SQL
  end

  def down
    # This migration is not reversible - we've removed CSML support
    raise ActiveRecord::IrreversibleMigration
  end
end
