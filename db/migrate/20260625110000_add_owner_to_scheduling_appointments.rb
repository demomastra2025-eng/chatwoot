class AddOwnerToSchedulingAppointments < ActiveRecord::Migration[7.1]
  def change
    add_reference :scheduling_appointments, :owner, foreign_key: { to_table: :users }, index: true

    reversible do |dir|
      dir.up do
        backfill_owner_from_contact
      end
    end
  end

  private

  def backfill_owner_from_contact
    execute <<~SQL.squish
      UPDATE scheduling_appointments
      SET owner_id = contacts.owner_id
      FROM contacts
      WHERE scheduling_appointments.contact_id = contacts.id
        AND scheduling_appointments.account_id = contacts.account_id
        AND scheduling_appointments.owner_id IS NULL
        AND contacts.owner_id IS NOT NULL
    SQL
  end
end
