class AddTitleToSchedulingAppointments < ActiveRecord::Migration[7.1]
  def change
    add_column :scheduling_appointments, :title, :string
  end
end
