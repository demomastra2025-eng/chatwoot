# Helpers for the CRM lifecycle expand migrations (20261004120000..193200). The test database already carries the final
# schema, so an example first reverts the CRM objects those migrations add (inside the example's transaction, rolled
# back afterwards), which gives the PROD shape, and then runs the real migration classes against it.
#
# CREATE INDEX CONCURRENTLY and REINDEX CONCURRENTLY cannot run inside a transaction block, so the helper runs the
# migrations with the plain forms of those two statements; concurrency itself is covered by the volume rehearsal.
# rubocop:disable Metrics/ModuleLength -- one module keeps the revert, run and snapshot helpers of the series together
module CrmLifecycleMigrationHelper
  MIGRATIONS = {
    columns: %w[20261004120000_expand_crm_lifecycle_columns ExpandCrmLifecycleColumns],
    tables: %w[20261004120100_create_crm_lifecycle_tables CreateCrmLifecycleTables],
    constraints: %w[20261004120200_add_crm_lifecycle_foreign_keys_and_checks AddCrmLifecycleForeignKeysAndChecks],
    catalogs: %w[20261004120250_seed_crm_task_catalogs SeedCrmTaskCatalogs],
    backfill: %w[20261004120300_backfill_crm_lifecycle_data BackfillCrmLifecycleData],
    indexes: %w[20261004120400_add_crm_lifecycle_indexes AddCrmLifecycleIndexes],
    validate: %w[20261004120500_validate_crm_lifecycle_constraints ValidateCrmLifecycleConstraints],
    exit_window_index: %w[20261004121500_add_crm_stage_visit_exit_window_index AddCrmStageVisitExitWindowIndex],
    captain: %w[20261004193000_create_captain_follow_up_attempts CreateCaptainFollowUpAttempts],
    reminders: %w[20261004193100_add_idempotency_key_to_reminders AddIdempotencyKeyToReminders],
    publication: %w[20261004193200_mark_legacy_crm_events_published MarkLegacyCrmEventsPublished]
  }.freeze
  CHAIN = MIGRATIONS.keys.freeze
  NEW_TABLES = %w[crm_stage_visits crm_stage_field_requirements crm_task_outcomes crm_task_types].freeze
  CRM_TABLES = (NEW_TABLES + %w[crm_tasks crm_deals crm_pipelines crm_events]).freeze
  CACHED_TABLES = (CRM_TABLES + %w[reminders captain_follow_up_attempts]).freeze
  ADDED_COLUMNS = {
    'crm_tasks' => %w[all_day due_on schedule_timezone completed_by_id cancelled_at cancelled_by_id cancellation_reason
                      reschedule_count context_kind task_type_id task_outcome_id],
    'crm_deals' => %w[waiting_until waiting_reason waiting_started_at waiting_set_by_id],
    'crm_pipelines' => %w[restrict_stage_skipping restrict_backward_move allow_stage_rule_override],
    'crm_events' => %w[source actor_kind before_data after_data causation_id schema_version command_key
                       performed_by_type performed_by_id published_at publication_attempts publication_error
                       publication_next_attempt_at]
  }.freeze
  METADATA_KEYS = %w[
    crm_tasks_schedule_cutover crm_tasks_schedule_backfilled crm_events_envelope_cutover
    crm_events_legacy_publication_baseline
  ].freeze

  def self.migration_class(name)
    file, class_name = MIGRATIONS.fetch(name)
    require Rails.root.join('db/migrate', file)
    class_name.constantize
  end

  def self.included(base)
    base.before { @crm_lifecycle_ddl_connection = ActiveRecord::Base.connection }
  end

  # Rails rolls the example's DDL back in after_teardown; the plans and column caches built on the reverted schema must
  # be dropped only after that.
  def after_teardown
    ddl_connection = @crm_lifecycle_ddl_connection
    super
  ensure
    if ddl_connection
      ddl_connection.clear_cache!
      CACHED_TABLES.each { |table| ddl_connection.schema_cache.clear_data_source_cache!(table) }
      [Crm::Task, Crm::Deal, Crm::Pipeline, Crm::Event, Crm::TaskType, Crm::TaskOutcome, Crm::StageVisit,
       Crm::StageFieldRequirement, Reminder, Captain::FollowUpAttempt].each(&:reset_column_information)
      @crm_lifecycle_ddl_connection = nil
    end
  end

  def db
    ActiveRecord::Base.connection
  end

  def revert_to_prod_shape!
    db.execute("DROP TABLE #{NEW_TABLES.join(', ')} CASCADE")
    ADDED_COLUMNS.each do |table, columns|
      db.execute("ALTER TABLE #{table} #{columns.map { |column| "DROP COLUMN #{column} CASCADE" }.join(', ')}")
    end
    db.execute("DELETE FROM ar_internal_metadata WHERE key IN (#{METADATA_KEYS.map { |key| db.quote(key) }.join(', ')})")
    reset_crm_schema_caches
  end

  def reset_crm_schema_caches
    db.clear_cache!
    CACHED_TABLES.each { |table| db.schema_cache.clear_data_source_cache!(table) }
  end

  def run_migration(name, times: 1)
    migration = CrmLifecycleMigrationHelper.migration_class(name).new
    allow(migration).to receive(:sleep)
    plain_concurrent_statements
    times.times { ActiveRecord::Migration.suppress_messages { migration.up } }
    reset_crm_schema_caches
    migration
  end

  def run_chain(*names, times: 1)
    times.times { names.each { |name| run_migration(name) } }
  end

  def plain_concurrent_statements
    allow(db).to receive(:add_index).and_wrap_original do |original, *args, **options|
      original.call(*args, **options.except(:algorithm))
    end
    allow(db).to receive(:execute).and_wrap_original do |original, sql, *rest, **options|
      original.call(sql.is_a?(String) ? sql.sub('REINDEX INDEX CONCURRENTLY', 'REINDEX INDEX') : sql, *rest, **options)
    end
  end

  def metadata(key)
    db.select_value("SELECT value FROM ar_internal_metadata WHERE key = #{db.quote(key)}")
  end

  def set_metadata(key, value)
    db.execute(<<~SQL.squish)
      INSERT INTO ar_internal_metadata (key, value, created_at, updated_at)
      VALUES (#{db.quote(key)}, #{db.quote(value)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
    SQL
  end

  # Logical column definitions, indexes and constraints (with their validity) of every table the series touches.
  # Additive migrations retain physical column positions, which need not match a schema.rb rebuild.
  def crm_schema_snapshot(table_names = CRM_TABLES)
    tables = table_names.map { |table| db.quote(table) }.join(', ')
    {
      columns: db.select_rows(<<~SQL.squish),
        SELECT table_name, column_name, data_type, is_nullable, column_default FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name IN (#{tables}) ORDER BY table_name, column_name
      SQL
      indexes: db.select_rows(<<~SQL.squish),
        SELECT tablename, indexname, indexdef FROM pg_indexes
        WHERE schemaname = current_schema() AND tablename IN (#{tables}) ORDER BY tablename, indexname
      SQL
      constraints: normalized_constraints(tables)
    }
  end

  # PostgreSQL deparses a CHECK expression with other parentheses and casts depending on how its text was given (the
  # test database was loaded from schema.rb, which holds already deparsed text), so CHECKs compare without them.
  def normalized_constraints(tables)
    db.select_rows(<<~SQL.squish).map do |table, name, type, validated, definition|
      SELECT conrelid::regclass::text, conname, contype::text, convalidated::text, pg_get_constraintdef(oid)
      FROM pg_constraint
      WHERE connamespace = current_schema()::regnamespace AND conrelid::regclass::text IN (#{tables})
      ORDER BY 1, 2
    SQL
      [table, name, type, validated, type == 'c' ? definition.gsub(/\s+/, '').gsub(/::[a-z]+(?:\[\])?/, '').delete('()') : definition]
    end
  end

  def invalid_indexes
    db.select_values(<<~SQL.squish)
      SELECT pg_class.relname FROM pg_index JOIN pg_class ON pg_class.oid = pg_index.indexrelid
      WHERE NOT pg_index.indisvalid AND pg_class.relnamespace = current_schema()::regnamespace
    SQL
  end

  def unvalidated_constraints
    db.select_values(<<~SQL.squish)
      SELECT conname FROM pg_constraint
      WHERE NOT convalidated AND connamespace = current_schema()::regnamespace
    SQL
  end
end

# rubocop:enable Metrics/ModuleLength

RSpec.configure do |config|
  config.include CrmLifecycleMigrationHelper, :crm_lifecycle_ddl
end
