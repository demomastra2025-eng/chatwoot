class ValidateCrmAppointmentAutomationConstraints < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    validate_foreign_key :scheduling_appointments, :crm_deals, name: 'fk_appointment_crm_deal'
    validate_check_constraint :crm_pipelines, name: 'crm_pipeline_appointment_config_object'
    validate_check_constraint :crm_deals, name: 'crm_deal_appointment_config_types'
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Validated CRM constraints are retained'
  end
end
