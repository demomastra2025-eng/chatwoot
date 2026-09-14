class AddCaptainControlToConversations < ActiveRecord::Migration[7.1]
  def change
    add_column :conversations, :captain_control_state, :string, null: false, default: 'ai'
    add_column :conversations, :captain_control_generation, :bigint, null: false, default: 0
    add_column :conversations, :captain_handoff_applied_at, :datetime
  end
end
