class AddDeletionAttemptIdToInboxes < ActiveRecord::Migration[7.1]
  def change
    add_column :inboxes, :deletion_attempt_id, :string
  end
end
