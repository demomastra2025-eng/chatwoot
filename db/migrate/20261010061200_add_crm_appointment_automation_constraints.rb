class AddCrmAppointmentAutomationConstraints < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    attempts = 0
    begin
      add_constraints
    rescue ActiveRecord::LockWaitTimeout
      attempts += 1
      raise if attempts >= 5

      sleep(1)
      retry
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'CRM appointment constraints preserve retained data'
  end

  private

  def add_constraints
    transaction do
      execute("SET LOCAL lock_timeout = '2s'")
      add_foreign_key :scheduling_appointments, :crm_deals, column: :crm_deal_id, on_delete: :nullify,
                      validate: false, name: 'fk_appointment_crm_deal' unless foreign_key_exists?(:scheduling_appointments, name: 'fk_appointment_crm_deal')
      add_check_constraint :crm_pipelines, "jsonb_typeof(appointment_automation) = 'object'",
                           name: 'crm_pipeline_appointment_config_object', validate: false, if_not_exists: true
      add_check_constraint :crm_deals, "jsonb_typeof(appointment_plan) = 'array' AND jsonb_typeof(appointment_automation_state) = 'object'",
                           name: 'crm_deal_appointment_config_types', validate: false, if_not_exists: true
    end
  end

end
