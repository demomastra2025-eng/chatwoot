class AddAccessRoleCanonicalizedAtToAccounts < ActiveRecord::Migration[7.0]
  def up
    add_column :accounts, :access_role_canonicalized_at, :datetime
    add_index :accounts, :access_role_canonicalized_at

    execute <<~SQL.squish
      UPDATE accounts
      SET access_role_canonicalized_at = canonical_roles.first_canonical_update
      FROM (
        SELECT account_id, MIN(updated_at) AS first_canonical_update
        FROM access_roles
        WHERE grant_source = 'canonical'
        GROUP BY account_id
      ) AS canonical_roles
      WHERE accounts.id = canonical_roles.account_id
        AND accounts.access_role_canonicalized_at IS NULL
    SQL
  end

  def down
    canonicalized_accounts = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*)
      FROM accounts
      WHERE access_role_canonicalized_at IS NOT NULL
    SQL
    if canonicalized_accounts.positive?
      raise ActiveRecord::IrreversibleMigration,
            'access_role_canonicalized_at cannot be removed after normalized role mutations'
    end

    remove_index :accounts, :access_role_canonicalized_at
    remove_column :accounts, :access_role_canonicalized_at
  end
end
