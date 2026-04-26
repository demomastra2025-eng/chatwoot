class AddCaptainAssistantToCampaigns < ActiveRecord::Migration[7.1]
  def change
    add_reference :campaigns, :captain_assistant, foreign_key: { to_table: :captain_assistants }
  end
end
