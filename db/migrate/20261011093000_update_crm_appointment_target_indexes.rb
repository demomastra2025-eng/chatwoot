class UpdateCrmAppointmentTargetIndexes < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  LOCK_TIMEOUT = '5s'.freeze
  LOCK_ATTEMPTS = 5
  STATEMENT_TIMEOUT = '30min'.freeze
  INDEXES = {
    'idx_crm_pipeline_calendar_target' => 'auto_create_from_calendar',
    'idx_crm_pipeline_medelement_target' => 'auto_create_from_medelement'
  }.freeze

  def up
    without_statement_timeout do
      INDEXES.each do |name, source_key|
        verify_known_target_index!(name, source_key)
        next if fixed_valid_index?(name, source_key)

        replace_target_index(name, "#{name}_with_master", source_key)
      end
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'The old predicates cannot be restored while disabled pipelines retain source flags.'
  end

  private

  def replace_target_index(name, replacement, source_key)
    prepare_replacement(replacement, source_key)
    remove_replaced_index(name, replacement, source_key)
    with_short_lock_timeout do
      execute "ALTER INDEX #{quote_table_name(replacement)} RENAME TO #{quote_column_name(name)}"
    end
  end

  def prepare_replacement(replacement, source_key)
    definition = index_definition(replacement)
    if definition
      unless target_index_shape?(definition) && normalize_predicate(definition['predicate']) == normalize_predicate(predicate(source_key))
        raise ActiveRecord::MigrationError, "Unexpected replacement index definition for #{replacement}"
      end
      execute("REINDEX INDEX CONCURRENTLY #{quote_table_name(replacement)}") unless definition['indisvalid']
    else
      add_index :crm_pipelines, :account_id, name: replacement, unique: true,
                                           where: predicate(source_key), algorithm: :concurrently
    end
  end

  # The release planner accepts only this verified swap, after a valid build.
  def remove_replaced_index(name, replacement, source_key)
    definition = index_definition(name)
    return unless definition

    raise ActiveRecord::MigrationError, "Unexpected index definition for #{name}" unless known_target_index?(definition, source_key)
    raise ActiveRecord::MigrationError, "Valid replacement missing for #{name}" unless fixed_valid_index?(replacement, source_key)

    remove_index :crm_pipelines, name: name, algorithm: :concurrently
  end

  def verify_known_target_index!(name, source_key)
    definition = index_definition(name)
    return unless definition

    raise ActiveRecord::MigrationError, "Unexpected index definition for #{name}" unless known_target_index?(definition, source_key)
  end

  def known_target_index?(definition, source_key)
    target_index_shape?(definition) && [legacy_predicate(source_key), predicate(source_key)].any? do |expected|
      normalize_predicate(definition['predicate']) == normalize_predicate(expected)
    end
  end

  def target_index_shape?(definition)
    definition['indisunique'] && definition['account_id_only']
  end

  def legacy_predicate(source_key)
    "active AND appointment_automation ->> '#{source_key}' = 'true'"
  end

  def predicate(source_key)
    "active AND appointment_automation ->> '#{source_key}' = 'true' " \
      "AND (appointment_automation ->> 'auto_create_deals') IS DISTINCT FROM 'false'"
  end

  def fixed_valid_index?(name, source_key)
    definition = index_definition(name)
    return false unless definition && definition['indisvalid'] && target_index_shape?(definition)

    normalize_predicate(definition['predicate']) == normalize_predicate(predicate(source_key))
  end

  def normalize_predicate(value)
    value.to_s.gsub(/::text|[\s()]/, '')
  end

  def index_definition(name)
    select_one <<~SQL.squish
      SELECT indisvalid, indisunique, pg_get_expr(indpred, indrelid) AS predicate,
             indnkeyatts = 1 AND indnatts = 1 AND indkey[0] = (
               SELECT attnum FROM pg_attribute WHERE attrelid = indrelid AND attname = 'account_id'
             ) AS account_id_only
      FROM pg_index
      WHERE indexrelid = to_regclass(#{quote(name)})
        AND indrelid = to_regclass('crm_pipelines')
    SQL
  end

  def with_short_lock_timeout
    attempt = 0
    begin
      attempt += 1
      transaction(requires_new: true) do
        execute("SET LOCAL lock_timeout = '#{LOCK_TIMEOUT}'")
        yield
      end
    rescue ActiveRecord::LockWaitTimeout
      raise if attempt >= LOCK_ATTEMPTS

      sleep(attempt)
      retry
    end
  end

  def without_statement_timeout
    previous = select_value('SHOW statement_timeout')
    execute("SET statement_timeout = '#{STATEMENT_TIMEOUT}'")
    yield
  ensure
    execute("SET statement_timeout = #{quote(previous)}") if previous
  end
end
