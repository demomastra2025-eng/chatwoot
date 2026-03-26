class AddGroupNameToCaptainCustomTools < ActiveRecord::Migration[7.1]
  def change
    add_column :captain_custom_tools, :group_name, :string
    add_index :captain_custom_tools, [:account_id, :group_name]
  end
end
