class AddPatientContactToSchedulingAppointments < ActiveRecord::Migration[7.1]
  # Expand step only: a nullable column is a metadata change. The NOT VALID foreign key, the concurrent index and the
  # key validation are separate follow-up migrations, so each ACCESS EXCLUSIVE step is short and bounded by a lock
  # timeout (retried a few times) instead of queueing reads and writes behind a long transaction on the table.
  disable_ddl_transaction!

  LOCK_TIMEOUT = '5s'.freeze
  LOCK_ATTEMPTS = 5

  def up
    with_short_lock_timeout do
      add_column :scheduling_appointments, :patient_contact_id, :bigint, if_not_exists: true
    end
  end

  # The follow-up migrations are rolled back first; any key or index still left on the column goes with it.
  def down
    with_short_lock_timeout do
      remove_reference :scheduling_appointments, :patient_contact, index: false
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
