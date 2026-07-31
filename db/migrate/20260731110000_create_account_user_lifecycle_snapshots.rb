class CreateAccountUserLifecycleSnapshots < ActiveRecord::Migration[7.0]
  def change
    create_table :account_user_lifecycle_snapshots do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :deactivated_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :role, null: false
      t.string :availability, null: false
      t.boolean :auto_offline, null: false, default: true
      t.bigint :custom_role_id
      t.bigint :agent_capacity_policy_id
      t.jsonb :team_ids, null: false, default: []
      t.jsonb :inbox_ids, null: false, default: []
      t.datetime :deactivated_at, null: false
      t.datetime :reactivated_at
      t.timestamps
    end

    add_index :account_user_lifecycle_snapshots,
              %i[account_id user_id],
              unique: true,
              where: 'reactivated_at IS NULL',
              name: 'index_account_user_lifecycle_snapshots_active'
    add_index :account_user_lifecycle_snapshots, :deactivated_at
  end
end
