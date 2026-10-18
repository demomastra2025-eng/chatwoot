class BackfillAgentBotAndChannelApiSecrets < ActiveRecord::Migration[7.1]
  def up
    # The agent bot half of this backfill is gone with the AgentBot model: a database built from scratch has no
    # agent bots to fill, and every existing database has already run it.
    Channel::Api.where(secret: nil).find_each do |channel|
      channel.update!(secret: SecureRandom.urlsafe_base64(24))
    end
  end

  def down
    # no-op: removing the columns in the previous migrations handles cleanup
  end
end
