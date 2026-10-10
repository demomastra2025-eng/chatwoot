class AddCrmAppointmentAutomationIndexes < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEXES = [
    [:scheduling_appointments, %i[account_id crm_deal_id starts_at], { name: 'idx_appointments_crm_deal', where: 'crm_deal_id IS NOT NULL' }],
    [:crm_deals, %i[appointment_automation_next_check_at id],
     { name: 'idx_crm_deals_appointment_due', where: 'appointment_automation_next_check_at IS NOT NULL AND archived_at IS NULL AND closed_at IS NULL' }],
    [:crm_pipelines, :account_id,
     { name: 'idx_crm_pipeline_calendar_target', unique: true, where: "active AND appointment_automation ->> 'auto_create_from_calendar' = 'true'" }],
    [:crm_pipelines, :account_id,
     { name: 'idx_crm_pipeline_medelement_target', unique: true, where: "active AND appointment_automation ->> 'auto_create_from_medelement' = 'true'" }],
    [:messages, %i[account_id created_at id], { name: 'idx_messages_first_inbound_cohort', where: 'message_type = 0 AND NOT private' }],
    [:messages, %i[conversation_id created_at id], { name: 'idx_messages_first_inbound_contact', where: 'message_type = 0 AND NOT private' }]
  ].freeze

  def up
    INDEXES.each do |table, columns, options|
      invalid = select_value(<<~SQL.squish)
        SELECT 1 FROM pg_index JOIN pg_class ON pg_class.oid = pg_index.indexrelid
        JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        WHERE pg_class.relname = #{quote(options.fetch(:name))} AND pg_namespace.nspname = current_schema() AND NOT pg_index.indisvalid
      SQL
      execute("REINDEX INDEX CONCURRENTLY #{quote_table_name(options.fetch(:name))}") if invalid.present?
      add_index table, columns, **options, algorithm: :concurrently, if_not_exists: true
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Additive CRM indexes are retained on application rollback'
  end
end
