class AddUsageModeToCaptainAssistants < ActiveRecord::Migration[7.0]
  def change
    add_column :captain_assistants, :usage_mode, :string, null: false, default: 'external_agent'
    add_index :captain_assistants, :usage_mode
  end
end
