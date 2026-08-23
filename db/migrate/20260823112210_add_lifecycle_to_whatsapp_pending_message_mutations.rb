class AddLifecycleToWhatsappPendingMessageMutations < ActiveRecord::Migration[7.1]
  def up
    add_column :whatsapp_pending_message_mutations, :status, :string, null: false, default: 'pending'
    add_column :whatsapp_pending_message_mutations, :attempt_count, :integer, null: false, default: 0
    add_column :whatsapp_pending_message_mutations, :last_attempted_at, :datetime
    add_column :whatsapp_pending_message_mutations, :terminal_reason, :string
    add_column :whatsapp_pending_message_mutations, :terminal_at, :datetime
    add_column :whatsapp_pending_message_mutations, :next_reconciliation_at, :datetime
    add_column :whatsapp_pending_message_mutations, :reconciliation_token, :string
    add_column :whatsapp_pending_message_mutations, :payload_scrubbed_at, :datetime

    add_index :whatsapp_pending_message_mutations, [:status, :next_reconciliation_at],
              name: 'idx_wa_pending_mutations_reconciliation'

    execute <<~SQL.squish
      UPDATE whatsapp_pending_message_mutations
      SET provider_timestamp = provider_timestamp / 1000
      WHERE provider_timestamp >= 1000000000000
    SQL
  end

  def down
    remove_index :whatsapp_pending_message_mutations, name: 'idx_wa_pending_mutations_reconciliation', if_exists: true
    remove_index :whatsapp_pending_message_mutations, name: 'idx_wa_pending_mutations_status_created', if_exists: true

    %i[
      status attempt_count last_attempted_at terminal_reason terminal_at next_reconciliation_at reconciliation_token
      payload_scrubbed_at
    ].each do |column|
      remove_column :whatsapp_pending_message_mutations, column if column_exists?(:whatsapp_pending_message_mutations, column)
    end
  end
end
