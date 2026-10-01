class ValidatePatientContactForeignKeyOnSchedulingAppointments < ActiveRecord::Migration[7.1]
  # VALIDATE CONSTRAINT takes SHARE UPDATE EXCLUSIVE, so reads and writes continue while existing rows are checked.
  def up
    validate_foreign_key :scheduling_appointments, :contacts, column: :patient_contact_id
  end

  def down; end
end
