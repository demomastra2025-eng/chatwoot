class AddMedelementScheduleDaysResourceDateUniqueIndex < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  INDEX_NAME = 'idx_medelement_schedule_days_hook_resource_date'.freeze

  def up
    with_short_lock_timeout do
      execute("DROP INDEX CONCURRENTLY IF EXISTS #{quote_table_name(INDEX_NAME)}") if index_state == 'invalid'
      next if index_state == 'valid'

      add_index :medelement_schedule_days, %i[hook_id resource_id date],
                unique: true, name: INDEX_NAME, algorithm: :concurrently
    end
  end

  def down
    with_short_lock_timeout do
      execute("DROP INDEX CONCURRENTLY IF EXISTS #{quote_table_name(INDEX_NAME)}")
    end
  end

  private

  def index_state
    select_value(<<~SQL.squish)
      SELECT CASE WHEN pg_index.indisvalid THEN 'valid' ELSE 'invalid' END
      FROM pg_index
      JOIN pg_class ON pg_class.oid = pg_index.indexrelid
      JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
      WHERE pg_class.relname = #{quote(INDEX_NAME)} AND pg_namespace.nspname = current_schema()
    SQL
  end

  def with_short_lock_timeout
    previous = select_value('SHOW lock_timeout')
    execute("SET lock_timeout = '5s'")
    yield
  ensure
    execute("SET lock_timeout = #{quote(previous)}") if previous
  end
end
