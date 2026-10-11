# frozen_string_literal: true

class CreateCaptainStandaloneAgents < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  LOCK_TIMEOUT = '5s'.freeze
  LOCK_ATTEMPTS = 5
  STATEMENT_TIMEOUT = '30min'.freeze
  FOREIGN_KEYS = [
    [:captain_assistants, :captain_scenarios, { column: :legacy_scenario_id, on_delete: :nullify }],
    [:captain_agent_handoffs, :accounts, { column: :account_id }],
    [:captain_agent_handoffs, :captain_assistants,
     { column: [:source_assistant_id, :account_id], primary_key: [:id, :account_id], on_delete: :cascade,
       name: 'captain_agent_handoffs_source_assistant_id_account_fk' }],
    [:captain_agent_handoffs, :captain_assistants,
     { column: [:target_assistant_id, :account_id], primary_key: [:id, :account_id], on_delete: :cascade,
       name: 'captain_agent_handoffs_target_assistant_id_account_fk' }]
  ].freeze

  def up
    with_short_lock_timeout { add_agent_attributes }
    create_handoff_graph
    without_statement_timeout { add_agent_indexes }
    add_constraints
    preserve_legacy_scenario_history
    convert_legacy_scenarios
    without_statement_timeout { validate_constraints }
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Standalone agents and legacy scenario history must be retained'
  end

  private

  def convert_legacy_scenarios
    require Rails.root.join('enterprise/app/services/captain/legacy_scenario_conversion_service')
    Captain::LegacyScenarioConversionService::LegacyAssistant.reset_column_information
    report = Captain::LegacyScenarioConversionService.new.perform
    say "Standalone agents: #{report[:converted]} converted, #{report[:existing]} already mapped; review config.legacy_scenario_migration.warnings"
    report[:skipped].each { |item| say "Scenario #{item[:scenario_id]} retained without conversion: #{item[:warning]}" }
  end

  def add_agent_attributes
    add_column :captain_assistants, :active, :boolean, default: true, null: false unless column_exists?(:captain_assistants, :active)
    add_column :captain_assistants, :routing_description, :text unless column_exists?(:captain_assistants, :routing_description)
    add_column :captain_assistants, :legacy_scenario_id, :bigint unless column_exists?(:captain_assistants, :legacy_scenario_id)
  end

  def create_handoff_graph
    return if table_exists?(:captain_agent_handoffs)

    with_short_lock_timeout do
      create_table :captain_agent_handoffs do |t|
        t.references :account, null: false
        t.bigint :source_assistant_id, null: false
        t.bigint :target_assistant_id, null: false
        t.timestamps
      end
    end
  end

  def add_agent_indexes
    add_concurrent_index(:captain_assistants, :legacy_scenario_id, 'index_captain_assistants_on_legacy_scenario_id', unique: true)
    add_concurrent_index(:captain_assistants, [:id, :account_id], 'index_captain_assistants_on_id_and_account_id', unique: true)
    add_concurrent_index(:captain_agent_handoffs, [:source_assistant_id, :target_assistant_id],
                         'index_captain_agent_handoffs_on_source_and_target', unique: true)
    add_concurrent_index(:captain_agent_handoffs, :target_assistant_id, 'index_captain_agent_handoffs_on_target_assistant_id')
  end

  def add_concurrent_index(table, columns, name, unique: false)
    definition = connection.indexes(table).find { |index| index.name == name }
    if definition && (definition.columns != Array(columns).map(&:to_s) || definition.unique != unique)
      raise ActiveRecord::MigrationError, "Unexpected index definition for #{name}"
    end
    invalid = select_value("SELECT 1 FROM pg_index WHERE indexrelid = to_regclass(#{quote(name)}) AND NOT indisvalid")
    execute("REINDEX INDEX CONCURRENTLY #{quote_table_name(name)}") if invalid.present?
    add_index table, columns, name: name, unique: unique, algorithm: :concurrently, if_not_exists: true unless definition
  end

  def add_constraints
    FOREIGN_KEYS.each do |from_table, to_table, options|
      with_short_lock_timeout { add_foreign_key from_table, to_table, **options, validate: false, if_not_exists: true }
    end
    unless check_constraint_exists?(:captain_agent_handoffs, name: :captain_agent_handoffs_no_self)
      with_short_lock_timeout do
        add_check_constraint :captain_agent_handoffs, 'source_assistant_id <> target_assistant_id',
                             name: :captain_agent_handoffs_no_self, validate: false
      end
    end
  end

  # This exact history-preserving relaxation is checked by the release planner.
  def preserve_legacy_scenario_history
    with_short_lock_timeout do
      change_column_null(:captain_scenarios, :assistant_id, true)
    end
  end

  def validate_constraints
    FOREIGN_KEYS.each do |from_table, _to_table, options|
      constraint = connection.foreign_keys(from_table).find { |key| Array(key.column) == Array(options[:column]).map(&:to_s) }
      validate_foreign_key from_table, name: constraint.name unless constraint.validated?
    end
    constraint = connection.check_constraints(:captain_agent_handoffs).find { |check| check.name == 'captain_agent_handoffs_no_self' }
    validate_check_constraint :captain_agent_handoffs, name: constraint.name unless constraint.validate?
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
