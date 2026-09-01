class BackfillAgentBotAndChannelApiSecrets < ActiveRecord::Migration[7.1]
  class MigrationAgentBot < ActiveRecord::Base
    self.table_name = 'agent_bots'
  end

  class MigrationApiChannel < ActiveRecord::Base
    self.table_name = 'channel_api'
  end

  def up
    MigrationAgentBot.where(secret: nil).find_each do |agent_bot|
      agent_bot.update!(secret: SecureRandom.urlsafe_base64(24))
    end

    MigrationApiChannel.where(secret: nil).find_each do |channel|
      channel.update!(secret: SecureRandom.urlsafe_base64(24))
    end
  end

  def down
    # no-op: removing the columns in the previous migrations handles cleanup
  end
end
