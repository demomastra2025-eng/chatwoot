class AddWorkspaceWorkingHoursInheritanceToInboxes < ActiveRecord::Migration[7.1]
  def change
    add_column :inboxes, :inherit_working_hours_from_account, :boolean, default: false, null: false
  end
end
