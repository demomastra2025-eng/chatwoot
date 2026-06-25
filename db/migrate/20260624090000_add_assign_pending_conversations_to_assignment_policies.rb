class AddAssignPendingConversationsToAssignmentPolicies < ActiveRecord::Migration[7.1]
  def change
    add_column :assignment_policies, :assign_pending_conversations, :boolean, default: false, null: false
  end
end
