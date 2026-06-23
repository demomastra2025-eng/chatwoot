class RemovePipelineTypeFromCrmPipelines < ActiveRecord::Migration[7.1]
  def up
    remove_index :crm_pipelines,
                 name: :index_crm_pipelines_on_account_main_type_active,
                 if_exists: true
    remove_index :crm_pipelines,
                 name: :index_crm_pipelines_on_account_ai_type_active,
                 if_exists: true
    remove_check_constraint :crm_pipelines,
                            name: :chk_crm_pipelines_pipeline_type,
                            if_exists: true
    remove_column :crm_pipelines, :pipeline_type, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
