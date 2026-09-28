class EnsureCrmEventsCorrelationIdDefault < ActiveRecord::Migration[7.1]
  def up
    add_column :crm_events, :correlation_id, :uuid unless column_exists?(:crm_events, :correlation_id)

    execute <<~SQL.squish
      UPDATE crm_events
      SET correlation_id = gen_random_uuid()
      WHERE correlation_id IS NULL
    SQL

    change_column_default :crm_events, :correlation_id, from: nil, to: -> { 'gen_random_uuid()' }
    change_column_null :crm_events, :correlation_id, false
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'correlation_id may predate this compatibility migration; removing its guarantees would reintroduce failed event writes'
  end
end
