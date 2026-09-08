class AddWaitingStateToCrmDeals < ActiveRecord::Migration[7.1]
  def change
    add_column :crm_deals, :waiting_until, :datetime
    add_column :crm_deals, :waiting_reason, :text
    add_column :crm_deals, :waiting_started_at, :datetime
    add_reference :crm_deals, :waiting_set_by, foreign_key: { to_table: :users, on_delete: :nullify }

    add_index :crm_deals,
              [:account_id, :waiting_until],
              where: 'waiting_until IS NOT NULL AND archived_at IS NULL',
              name: 'index_crm_deals_on_active_waiting_until'

    add_check_constraint :crm_deals,
                         <<~SQL.squish,
                           (waiting_until IS NULL AND waiting_reason IS NULL AND waiting_started_at IS NULL) OR
                           (waiting_until IS NOT NULL AND LENGTH(BTRIM(waiting_reason)) > 0 AND waiting_started_at IS NOT NULL)
                         SQL
                         name: 'crm_deals_waiting_state_complete'
  end
end
