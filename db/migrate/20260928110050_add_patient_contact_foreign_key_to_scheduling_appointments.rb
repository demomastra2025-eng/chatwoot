class AddPatientContactForeignKeyToSchedulingAppointments < ActiveRecord::Migration[7.1]
  # ADD FOREIGN KEY ... NOT VALID needs SHARE ROW EXCLUSIVE on both tables but checks no rows; it runs in its own short
  # transaction with a lock timeout (retried a few times), so a long transaction on contacts cannot stall appointments.
  # It is validated by 20260928110200 without blocking writes.
  disable_ddl_transaction!

  LOCK_TIMEOUT = '5s'.freeze
  LOCK_ATTEMPTS = 5

  def up
    with_short_lock_timeout do
      add_foreign_key :scheduling_appointments, :contacts, column: :patient_contact_id, on_delete: :nullify,
                                                           validate: false, if_not_exists: true
    end
  end

  def down
    with_short_lock_timeout do
      remove_foreign_key :scheduling_appointments, :contacts, column: :patient_contact_id, if_exists: true
    end
  end

  private

  def with_short_lock_timeout
    attempt = 0
    begin
      attempt += 1
      transaction do
        execute("SET LOCAL lock_timeout = '#{LOCK_TIMEOUT}'")
        yield
      end
    rescue ActiveRecord::LockWaitTimeout
      raise if attempt >= LOCK_ATTEMPTS

      sleep(attempt)
      retry
    end
  end
end
