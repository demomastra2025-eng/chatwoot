class AddCrmStageEntryRules < ActiveRecord::Migration[7.1]
  def change
    add_pipeline_rule_columns
    create_stage_field_requirements
  end

  private

  def add_pipeline_rule_columns
    add_column :crm_pipelines, :restrict_stage_skipping, :boolean, default: false, null: false
    add_column :crm_pipelines, :restrict_backward_move, :boolean, default: false, null: false
    add_column :crm_pipelines, :allow_stage_rule_override, :boolean, default: false, null: false
  end

  def create_stage_field_requirements
    create_table :crm_stage_field_requirements do |t|
      t.references :account, null: false, foreign_key: true
      t.references :stage, null: false, foreign_key: { to_table: :crm_stages }
      t.references :field_definition, null: true, foreign_key: { to_table: :crm_field_definitions }
      t.string :field_key, null: false
      t.boolean :required, null: false, default: true
      t.jsonb :validation, null: false, default: {}
      t.jsonb :role_exemptions, null: false, default: []
      t.timestamps
    end

    add_index :crm_stage_field_requirements,
              [:stage_id, :field_key],
              unique: true,
              name: 'index_crm_stage_requirements_on_stage_and_field'
    add_index :crm_stage_field_requirements,
              [:account_id, :stage_id],
              name: 'index_crm_stage_requirements_on_account_and_stage'
  end
end
