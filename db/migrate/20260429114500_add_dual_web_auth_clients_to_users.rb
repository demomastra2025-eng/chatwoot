class AddDualWebAuthClientsToUsers < ActiveRecord::Migration[7.1]
  def up
    return unless table_exists?(:users)

    add_column :users, :active_web_desktop_auth_client_id, :string unless column_exists?(:users, :active_web_desktop_auth_client_id)
    add_column :users, :active_web_desktop_auth_client_set_at, :datetime unless column_exists?(:users, :active_web_desktop_auth_client_set_at)
    add_column :users, :active_web_mobile_auth_client_id, :string unless column_exists?(:users, :active_web_mobile_auth_client_id)
    add_column :users, :active_web_mobile_auth_client_set_at, :datetime unless column_exists?(:users, :active_web_mobile_auth_client_set_at)

    backfill_desktop_auth_client
  end

  def down
    return unless table_exists?(:users)

    remove_column :users, :active_web_mobile_auth_client_set_at if column_exists?(:users, :active_web_mobile_auth_client_set_at)
    remove_column :users, :active_web_mobile_auth_client_id if column_exists?(:users, :active_web_mobile_auth_client_id)
    remove_column :users, :active_web_desktop_auth_client_set_at if column_exists?(:users, :active_web_desktop_auth_client_set_at)
    remove_column :users, :active_web_desktop_auth_client_id if column_exists?(:users, :active_web_desktop_auth_client_id)
  end

  private

  def backfill_desktop_auth_client
    return unless column_exists?(:users, :active_auth_client_id)
    return unless column_exists?(:users, :active_web_desktop_auth_client_id)

    execute <<~SQL.squish
      UPDATE users
      SET active_web_desktop_auth_client_id = active_auth_client_id,
          active_web_desktop_auth_client_set_at = active_auth_client_set_at
      WHERE active_auth_client_id IS NOT NULL
        AND active_web_desktop_auth_client_id IS NULL
    SQL
  end
end
