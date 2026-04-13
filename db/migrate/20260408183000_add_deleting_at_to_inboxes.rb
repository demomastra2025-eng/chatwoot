class AddDeletingAtToInboxes < ActiveRecord::Migration[7.0]
  def change
    add_column :inboxes, :deleting_at, :datetime
    add_index :inboxes, [:account_id, :deleting_at]
  end
end
