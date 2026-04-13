class CreateLlmEventAnnotations < ActiveRecord::Migration[7.1]
  def change
    create_table :llm_event_annotations do |t|
      t.references :account, null: false, foreign_key: true
      t.references :llm_event, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.text :body, null: false

      t.timestamps
    end

    add_index :llm_event_annotations,
              [:account_id, :llm_event_id, :created_at],
              name: 'index_llm_event_annotations_on_account_event_created_at'
  end
end
