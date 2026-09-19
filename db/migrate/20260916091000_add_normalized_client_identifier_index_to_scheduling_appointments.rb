class AddNormalizedClientIdentifierIndexToSchedulingAppointments < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = 'idx_scheduling_appointments_account_normalized_identifier'.freeze

  def up
    execute <<~SQL.squish
      CREATE INDEX CONCURRENTLY IF NOT EXISTS #{INDEX_NAME}
      ON scheduling_appointments (account_id, regexp_replace(client_identifier, '[^0-9]', '', 'g'))
      WHERE client_identifier IS NOT NULL
    SQL
  end

  def down
    execute "DROP INDEX CONCURRENTLY IF EXISTS #{INDEX_NAME}"
  end
end
