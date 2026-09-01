class ConvertCsmlBotsToWebhookBots < ActiveRecord::Migration[7.0]
  class MigrationAgentBot < ActiveRecord::Base
    self.table_name = 'agent_bots'
  end

  def up
    # Find all CSML bots (bot_type = 1) and convert them to webhook (bot_type = 0)
    MigrationAgentBot.where(bot_type: 1).find_each do |bot|
      bot.update(bot_type: 0, bot_config: {})
    end
  end

  def down
    # This migration is not reversible - we've removed CSML support
    raise ActiveRecord::IrreversibleMigration
  end
end
