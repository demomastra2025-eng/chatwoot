# frozen_string_literal: true

class AddExclusionRulesToAssignmentPolicies < ActiveRecord::Migration[7.1]
  def change
    add_column :assignment_policies, :exclusion_rules, :jsonb, null: false, default: {}
  end
end
