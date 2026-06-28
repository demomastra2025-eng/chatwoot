class AddOutcomeNoteToCrmTasks < ActiveRecord::Migration[7.0]
  def change
    add_column :crm_tasks, :outcome_note, :text
  end
end
