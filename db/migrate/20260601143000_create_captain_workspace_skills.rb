class CreateCaptainWorkspaceSkills < ActiveRecord::Migration[7.1]
  def change
    create_table :captain_skills do |t|
      t.references :account, null: false, index: true, foreign_key: true
      t.string :slug, null: false
      t.string :name, null: false
      t.string :group_name
      t.text :description, null: false
      t.text :content, null: false
      t.string :source_url
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :captain_skills, [:account_id, :slug], unique: true
  end
end
