class AddClosingReasonsToCrmDealsAndStages < ActiveRecord::Migration[7.1]
  def change
    add_column :crm_stages, :closing_reason_options, :jsonb, default: [], null: false
    add_column :crm_stages, :closing_reason_required, :boolean, default: false, null: false
    add_column :crm_deals, :closing_reasons, :jsonb, default: [], null: false
  end
end
