class AddVisibilityToCaptainKnowledgeItems < ActiveRecord::Migration[7.1]
  def change
    add_column :captain_assistant_responses, :visibility, :integer, null: false, default: 0
    add_index :captain_assistant_responses, [:account_id, :visibility], name: 'idx_captain_responses_account_visibility'

    add_column :captain_documents, :visibility, :integer, null: false, default: 0
    add_index :captain_documents, [:account_id, :visibility], name: 'idx_captain_documents_account_visibility'
  end
end
