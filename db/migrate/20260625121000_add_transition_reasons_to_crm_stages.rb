class AddTransitionReasonsToCrmStages < ActiveRecord::Migration[7.1]
  def change
    add_column :crm_stages, :transition_reason_options, :jsonb, default: [], null: false
    add_column :crm_stages, :transition_reason_required, :boolean, default: false, null: false
  end
end
