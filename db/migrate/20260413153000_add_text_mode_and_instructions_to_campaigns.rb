class AddTextModeAndInstructionsToCampaigns < ActiveRecord::Migration[7.0]
  def change
    add_column :campaigns, :text_mode, :integer, null: false, default: 0
    add_column :campaigns, :instructions, :text
  end
end
