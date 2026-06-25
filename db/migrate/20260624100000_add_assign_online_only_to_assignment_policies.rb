class AddAssignOnlineOnlyToAssignmentPolicies < ActiveRecord::Migration[7.1]
  def change
    add_column :assignment_policies, :assign_online_only, :boolean, default: true, null: false
  end
end
