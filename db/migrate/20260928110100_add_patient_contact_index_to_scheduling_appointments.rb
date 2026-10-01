class AddPatientContactIndexToSchedulingAppointments < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = 'index_scheduling_appointments_on_patient_contact_id'.freeze

  # A failed or cancelled concurrent build leaves an INVALID index under this name, which if_not_exists alone would
  # accept for good; it is rebuilt concurrently first (a valid index is left untouched).
  def change
    reversible { |direction| direction.up { rebuild_invalid_index! } }
    add_index :scheduling_appointments, :patient_contact_id, name: INDEX_NAME, algorithm: :concurrently, if_not_exists: true
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
