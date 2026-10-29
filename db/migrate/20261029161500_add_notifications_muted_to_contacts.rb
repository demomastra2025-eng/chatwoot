class AddNotificationsMutedToContacts < ActiveRecord::Migration[7.2]
  def change
    add_column :contacts, :notifications_muted, :boolean, default: false, null: false
  end
end
