class ExtendCrmEventsForDomainFacts < ActiveRecord::Migration[7.1]
  def up
    add_event_envelope_columns
    backfill_event_envelopes
    add_event_envelope_indexes
  end

  def down
    remove_index :crm_events, name: 'index_crm_events_on_command_dedupe'
    remove_index :crm_events, name: 'index_crm_events_on_unpublished'
    remove_index :crm_events, column: %i[account_id correlation_id]

    change_table :crm_events, bulk: true do |t|
      t.remove :source, :actor_kind, :before_data, :after_data, :correlation_id, :causation_id, :schema_version,
               :command_key, :performed_by_type, :performed_by_id, :published_at, :publication_attempts, :publication_error
    end
  end

  private

  def add_event_envelope_columns
    change_table :crm_events, bulk: true do |t|
      t.string :source, null: false, default: 'system'
      t.string :actor_kind
      t.jsonb :before_data, null: false, default: {}
      t.jsonb :after_data, null: false, default: {}
      t.uuid :correlation_id
      t.uuid :causation_id
      t.integer :schema_version, null: false, default: 1
      t.string :command_key
      t.string :performed_by_type
      t.bigint :performed_by_id
      t.datetime :published_at
      t.integer :publication_attempts, null: false, default: 0
      t.text :publication_error
    end
  end

  def backfill_event_envelopes
    backfill = execute <<~SQL.squish
      UPDATE crm_events
      SET correlation_id = gen_random_uuid(),
          actor_kind = CASE WHEN actor_id IS NULL THEN 'System' ELSE 'User' END,
          published_at = created_at
      WHERE correlation_id IS NULL
    SQL
    say "Backfilled envelope for #{backfill.cmd_tuples} CRM events"
    change_column_null :crm_events, :correlation_id, false
  end

  def add_event_envelope_indexes
    add_index :crm_events, %i[account_id correlation_id]
    add_index :crm_events, %i[published_at id],
              where: 'published_at IS NULL',
              name: 'index_crm_events_on_unpublished'
    add_index :crm_events,
              %i[account_id eventable_type eventable_id event_type command_key],
              unique: true,
              where: 'command_key IS NOT NULL',
              name: 'index_crm_events_on_command_dedupe'
  end
end
