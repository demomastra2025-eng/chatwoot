class EnableAssignmentNotificationInboxFlags < ActiveRecord::Migration[7.1]
  TASK_ASSIGNMENT_INBOX_FLAG = 512
  APPOINTMENT_ASSIGNMENT_INBOX_FLAG = 1024
  DEAL_ASSIGNMENT_INBOX_FLAG = 2048
  ASSIGNMENT_INBOX_FLAGS = TASK_ASSIGNMENT_INBOX_FLAG | APPOINTMENT_ASSIGNMENT_INBOX_FLAG | DEAL_ASSIGNMENT_INBOX_FLAG

  def up
    execute <<~SQL.squish
      UPDATE notification_settings
      SET inbox_flags = inbox_flags | #{ASSIGNMENT_INBOX_FLAGS}
    SQL
  end

  def down
    execute <<~SQL.squish
      UPDATE notification_settings
      SET inbox_flags = inbox_flags & ~#{ASSIGNMENT_INBOX_FLAGS}
    SQL
  end
end
