class AddActiveAuthClientToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :active_auth_client_id, :string
    add_column :users, :active_auth_client_set_at, :datetime
  end
end
