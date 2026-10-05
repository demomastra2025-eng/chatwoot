class AddCrmLifecycleIndexes < ActiveRecord::Migration[7.1]
  # Step 5 of the CRM lifecycle expand: every index is built CONCURRENTLY (no write lock), after the backfill so
  # the updates before it do not maintain them. A failed or cancelled concurrent build leaves an INVALID index under
  # the name, which if_not_exists alone would accept for good, so it is rebuilt first (a valid index is left alone).
  # The long builds run without the request statement timeout and restore it afterwards.
  disable_ddl_transaction!

  STATEMENT_TIMEOUT = '30min'.freeze
  INDEXES = [
    [:crm_tasks, %i[account_id due_on], { where: 'archived_at IS NULL', name: 'index_crm_tasks_on_active_due_on' }],
    [:crm_tasks, :completed_by_id, {}],
    [:crm_tasks, :cancelled_by_id, {}],
    [:crm_tasks, :task_type_id, {}],
    [:crm_tasks, :task_outcome_id, {}],
    [:crm_tasks, %i[account_id task_type_id due_at], { name: 'index_crm_tasks_on_account_type_due_at' }],
    [:crm_deals, :waiting_set_by_id, {}],
    [:crm_deals, %i[account_id waiting_until],
     { where: 'waiting_until IS NOT NULL AND archived_at IS NULL', name: 'index_crm_deals_on_active_waiting_until' }],
    [:crm_events, %i[account_id correlation_id], {}],
    [:crm_events, %i[published_at id], { where: 'published_at IS NULL', name: 'index_crm_events_on_unpublished' }],
    [:crm_events, %i[publication_next_attempt_at id],
     { where: 'published_at IS NULL', name: 'idx_crm_events_ready_for_publication' }],
    [:crm_events, %i[account_id eventable_type eventable_id event_type command_key],
     { unique: true, where: 'command_key IS NOT NULL', name: 'index_crm_events_on_command_dedupe' }],
    [:crm_stage_visits, :account_id, {}],
    [:crm_stage_visits, :deal_id, {}],
    [:crm_stage_visits, :pipeline_id, {}],
    [:crm_stage_visits, :stage_id, {}],
    [:crm_stage_visits, :deal_id,
     { unique: true, where: 'exited_at IS NULL', name: 'index_crm_stage_visits_on_active_deal' }],
    [:crm_stage_visits, %i[account_id entered_at], {}],
    [:crm_stage_visits, :correlation_id, {}]
  ].freeze

  def up
    without_statement_timeout do
      INDEXES.each do |table, columns, options|
        rebuild_invalid_index!(options[:name] || index_name(table, columns))
        add_index table, columns, **options, algorithm: :concurrently, if_not_exists: true
      end
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'CRM lifecycle schema is additive; roll back application behavior without removing retained CRM data'
  end

  private

  def rebuild_invalid_index!(name)
    invalid = select_value(<<~SQL.squish)
      SELECT 1 FROM pg_index
      JOIN pg_class ON pg_class.oid = pg_index.indexrelid
      JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
      WHERE pg_class.relname = #{quote(name)} AND pg_namespace.nspname = current_schema() AND NOT pg_index.indisvalid
    SQL
    return if invalid.blank?

    execute("REINDEX INDEX CONCURRENTLY #{quote_table_name(name)}")
  end

  def without_statement_timeout
    previous = select_value('SHOW statement_timeout')
    execute("SET statement_timeout = '#{STATEMENT_TIMEOUT}'")
    yield
  ensure
    execute("SET statement_timeout = #{quote(previous)}") if previous
  end
end
