class AddCrmStageVisitExitWindowIndex < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  INDEX_NAME = 'index_crm_stage_visits_on_account_id_and_exited_at'.freeze

  # A failed or cancelled concurrent build leaves an INVALID index under this name, which index_exists? and
  # if_not_exists alone would accept for good; it is rebuilt concurrently first (a valid index is left untouched).
  def up
    rebuild_invalid_index!
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

  private

  def rebuild_invalid_index!
    invalid = select_value(<<~SQL.squish)
      SELECT 1 FROM pg_index
      JOIN pg_class ON pg_class.oid = pg_index.indexrelid
      JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
      WHERE pg_class.relname = #{quote(INDEX_NAME)} AND pg_namespace.nspname = current_schema() AND NOT pg_index.indisvalid
    SQL
    return if invalid.blank?

    execute("REINDEX INDEX CONCURRENTLY #{quote_table_name(INDEX_NAME)}")
  end
end
