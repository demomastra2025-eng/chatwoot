class ExpandCrmLifecycleColumns < ActiveRecord::Migration[7.1]
  # Step 1 of the CRM lifecycle expand (120000 columns, 120100 tables, 120200 foreign keys and checks as NOT VALID,
  # 120250 catalogs, 120300 batched backfill, 120400 concurrent indexes, 120500 validation; 193200 closes the event
  # publication gap).
  # Metadata-only column additions: a nullable column or a constant default is not a table rewrite. Every table is
  # altered in its own short transaction under a lock timeout (retried), like 20260928110000, so a long transaction on
  # a CRM table cannot queue the old application's reads and writes behind this DDL. Nothing here backfills, indexes or
  # constrains: the old application keeps writing while the schema grows.
  disable_ddl_transaction!

  LOCK_TIMEOUT = '5s'.freeze
  LOCK_ATTEMPTS = 5
  DEFAULT_TIMEZONE = 'Asia/Almaty'.freeze
  # Rows that exist when a column first appears are history; rows written afterwards are live. The boundaries are
  # persisted before the columns are added so a re-run, or an environment that already has the columns (epoch), can
  # never treat live rows as legacy data later (see 20261004120300 and 20261004193200).
  TASK_CUTOVER_KEY = 'crm_tasks_schedule_cutover'.freeze
  EVENT_CUTOVER_KEY = 'crm_events_envelope_cutover'.freeze

  def up
    unless column_exists?(:crm_events, :correlation_id)
      raise ActiveRecord::MigrationError, 'crm_events.correlation_id must exist (see 20260916103000) before the CRM lifecycle expand'
    end

    record_cutover(TASK_CUTOVER_KEY, :crm_tasks, :schedule_timezone)
    record_cutover(EVENT_CUTOVER_KEY, :crm_events, :published_at)
    short_lock { add_task_columns }
    short_lock { add_deal_columns }
    short_lock { add_pipeline_columns }
    short_lock { add_event_columns }
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'CRM lifecycle schema is additive; roll back application behavior without removing retained CRM data'
  end

  private

  def record_cutover(key, table, column)
    column_present = column_exists?(table, column)
    return if column_present && stored_cutover(key)

    cutover = column_present ? Time.at(0).utc : Time.current
    execute <<~SQL.squish
      INSERT INTO ar_internal_metadata (key, value, created_at, updated_at)
      VALUES (#{connection.quote(key)}, #{connection.quote(cutover.utc.iso8601(6))}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = CURRENT_TIMESTAMP
    SQL
  end

  def stored_cutover(key)
    select_value("SELECT value FROM ar_internal_metadata WHERE key = #{connection.quote(key)}")
  end

  def add_task_columns
    add_column :crm_tasks, :all_day, :boolean, default: false, null: false, if_not_exists: true
    add_column :crm_tasks, :due_on, :date, if_not_exists: true
    add_column :crm_tasks, :schedule_timezone, :string, default: DEFAULT_TIMEZONE, null: false, if_not_exists: true
    add_column :crm_tasks, :completed_by_id, :bigint, if_not_exists: true
    add_column :crm_tasks, :cancelled_at, :datetime, if_not_exists: true
    add_column :crm_tasks, :cancelled_by_id, :bigint, if_not_exists: true
    add_column :crm_tasks, :cancellation_reason, :text, if_not_exists: true
    add_column :crm_tasks, :reschedule_count, :integer, default: 0, null: false, if_not_exists: true
    add_column :crm_tasks, :context_kind, :string, if_not_exists: true
    add_column :crm_tasks, :task_type_id, :bigint, if_not_exists: true
    add_column :crm_tasks, :task_outcome_id, :bigint, if_not_exists: true
  end

  def add_deal_columns
    add_column :crm_deals, :waiting_until, :datetime, if_not_exists: true
    add_column :crm_deals, :waiting_reason, :text, if_not_exists: true
    add_column :crm_deals, :waiting_started_at, :datetime, if_not_exists: true
    add_column :crm_deals, :waiting_set_by_id, :bigint, if_not_exists: true
  end

  def add_pipeline_columns
    %i[restrict_stage_skipping restrict_backward_move allow_stage_rule_override].each do |name|
      add_column :crm_pipelines, name, :boolean, default: false, null: false, if_not_exists: true
    end
  end

  def add_event_columns
    add_column :crm_events, :source, :string, default: 'system', null: false, if_not_exists: true
    add_column :crm_events, :actor_kind, :string, if_not_exists: true
    add_column :crm_events, :before_data, :jsonb, default: {}, null: false, if_not_exists: true
    add_column :crm_events, :after_data, :jsonb, default: {}, null: false, if_not_exists: true
    add_column :crm_events, :causation_id, :uuid, if_not_exists: true
    add_column :crm_events, :schema_version, :integer, default: 1, null: false, if_not_exists: true
    add_column :crm_events, :command_key, :string, if_not_exists: true
    add_column :crm_events, :performed_by_type, :string, if_not_exists: true
    add_column :crm_events, :performed_by_id, :bigint, if_not_exists: true
    add_column :crm_events, :published_at, :datetime, if_not_exists: true
    add_column :crm_events, :publication_attempts, :integer, default: 0, null: false, if_not_exists: true
    add_column :crm_events, :publication_error, :text, if_not_exists: true
    add_column :crm_events, :publication_next_attempt_at, :datetime,
               default: -> { 'CURRENT_TIMESTAMP' }, null: false, if_not_exists: true
  end

  def short_lock
    attempt = 0
    begin
      attempt += 1
      transaction do
        execute("SET LOCAL lock_timeout = '#{LOCK_TIMEOUT}'")
        yield
      end
    rescue ActiveRecord::LockWaitTimeout
      raise if attempt >= LOCK_ATTEMPTS

      sleep(attempt)
      retry
    end
  end
end
