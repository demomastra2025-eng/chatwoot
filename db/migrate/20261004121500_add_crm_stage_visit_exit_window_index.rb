class AddCrmStageVisitExitWindowIndex < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!
  INDEX_NAME = 'index_crm_stage_visits_on_account_id_and_exited_at'.freeze

  def up
    return if index_exists?(:crm_stage_visits, %i[account_id exited_at], name: INDEX_NAME)

    add_index :crm_stage_visits,
              %i[account_id exited_at],
              name: INDEX_NAME,
              where: 'exited_at IS NOT NULL',
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'CRM stage visit report index is additive'
  end
end
