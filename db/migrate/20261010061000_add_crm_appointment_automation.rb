class AddCrmAppointmentAutomation < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    short_lock do
      add_column :crm_pipelines, :appointment_automation, :jsonb, default: {}, null: false, if_not_exists: true
      add_column :crm_deals, :appointment_plan, :jsonb, default: [], null: false, if_not_exists: true
      add_column :crm_deals, :selected_appointment_id, :bigint, if_not_exists: true
      add_column :crm_deals, :appointment_automation_state, :jsonb, default: {}, null: false, if_not_exists: true
      add_column :crm_deals, :appointment_automation_next_check_at, :datetime, if_not_exists: true
      add_column :scheduling_appointments, :crm_deal_id, :bigint, if_not_exists: true
      add_column :scheduling_appointments, :attendance_confirmed_at, :datetime, if_not_exists: true
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Retain appointment links and automation history when rolling back application code'
  end

  private

  def short_lock
    attempt = 0
    begin
      attempt += 1
      transaction do
        execute("SET LOCAL lock_timeout = '2s'")
        yield
      end
    rescue ActiveRecord::LockWaitTimeout
      raise if attempt >= 5

      sleep(attempt)
      retry
    end
  end
end
