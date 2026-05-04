class EnableCaptainNotificationInboxFlags < ActiveRecord::Migration[7.1]
  CAPTAIN_NOTIFICATION_INBOX_FLAG = 256

  def up
    execute <<~SQL.squish
      UPDATE notification_settings
      SET inbox_flags = inbox_flags | #{CAPTAIN_NOTIFICATION_INBOX_FLAG}
    SQL
  end

  def down
    execute <<~SQL.squish
      UPDATE notification_settings
      SET inbox_flags = inbox_flags & ~#{CAPTAIN_NOTIFICATION_INBOX_FLAG}
    SQL
  end
end
