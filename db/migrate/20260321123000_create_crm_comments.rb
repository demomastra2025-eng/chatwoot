class CreateCrmComments < ActiveRecord::Migration[7.1]
  def change
    create_table :crm_comments do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.references :commentable, polymorphic: true, null: false, index: false
      t.references :user, null: false, foreign_key: true, index: true
      t.text :body, null: false
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :crm_comments,
              [:account_id, :commentable_type, :commentable_id, :created_at],
              name: 'index_crm_comments_on_account_and_commentable_created_at'
  end
end
