class AddPatientNamePartsToSchedulingAppointments < ActiveRecord::Migration[7.1]
  def change
    add_column :scheduling_appointments, :client_first_name, :string
    add_column :scheduling_appointments, :client_last_name, :string
    add_column :scheduling_appointments, :client_middle_name, :string
  end
end
