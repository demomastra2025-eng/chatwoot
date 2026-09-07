class AddCrmEventPublicationRetrySchedule < ActiveRecord::Migration[7.1]
  def change
    add_column :crm_events, :publication_next_attempt_at, :datetime, null: false, default: -> { 'CURRENT_TIMESTAMP' }
    add_index :crm_events, [:publication_next_attempt_at, :id],
              name: 'idx_crm_events_ready_for_publication', where: 'published_at IS NULL'
  end
end
