class AddIdempotencyKeyToReminders < ActiveRecord::Migration[7.1]
  def up
    add_column :reminders, :idempotency_key, :string
    add_index :reminders, [:account_id, :idempotency_key],
              unique: true,
              where: 'idempotency_key IS NOT NULL',
              name: 'idx_reminders_on_account_idempotency_key'
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Reminder idempotency keys are retained for delivery safety'
  end
end
