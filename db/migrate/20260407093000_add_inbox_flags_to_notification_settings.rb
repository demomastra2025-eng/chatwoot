class AddInboxFlagsToNotificationSettings < ActiveRecord::Migration[7.1]
  DEFAULT_INBOX_FLAGS = 255

  def up
    add_column :notification_settings, :inbox_flags, :integer, default: 0, null: false

    execute <<~SQL.squish
      UPDATE notification_settings
      SET inbox_flags = #{DEFAULT_INBOX_FLAGS}
      WHERE inbox_flags = 0
    SQL
  end

  def down
    remove_column :notification_settings, :inbox_flags
  end
end
