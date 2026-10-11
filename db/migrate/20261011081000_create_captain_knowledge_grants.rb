class CreateCaptainKnowledgeGrants < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  LOCK_TIMEOUT = '5s'.freeze
  LOCK_ATTEMPTS = 5
  STATEMENT_TIMEOUT = '30min'.freeze
  BATCH_SIZE = 5_000
  KNOWLEDGE_TABLES = {
    captain_documents: 'Captain::Document',
    captain_assistant_responses: 'Captain::AssistantResponse'
  }.freeze

  def up
    KNOWLEDGE_TABLES.each_key do |table|
      with_short_lock_timeout do
        add_column table, :restricted_to_assistants, :boolean, null: false, default: false, if_not_exists: true
      end
    end
    create_grant_table
    without_statement_timeout { add_record_index }
    add_constraints
    backfill_converted_agent_access
    without_statement_timeout { validate_constraints }
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Retain granted personal knowledge access when rolling back application behavior'
  end

  private

  def create_grant_table
    return if table_exists?(:captain_knowledge_grants)

    with_short_lock_timeout do
      create_table :captain_knowledge_grants do |t|
        t.references :account, null: false
        t.references :assistant, null: false
        t.references :knowledge_record, polymorphic: true, null: false, index: false
        t.timestamps
      end
    end
  end

  def add_record_index
    name = 'idx_captain_knowledge_grants_record_assistant'
    columns = %w[knowledge_record_type knowledge_record_id assistant_id]
    definition = connection.indexes(:captain_knowledge_grants).find { |index| index.name == name }
    if definition && (definition.columns != columns || !definition.unique)
      raise ActiveRecord::MigrationError, "Unexpected index definition for #{name}"
    end
    invalid = select_value("SELECT 1 FROM pg_index WHERE indexrelid = to_regclass(#{quote(name)}) AND NOT indisvalid")
    execute("REINDEX INDEX CONCURRENTLY #{quote_table_name(name)}") if invalid.present?
    add_index :captain_knowledge_grants, columns, unique: true, name: name, algorithm: :concurrently, if_not_exists: true unless definition
  end

  def add_constraints
    with_short_lock_timeout do
      add_foreign_key :captain_knowledge_grants, :accounts, column: :account_id, on_delete: :cascade, validate: false, if_not_exists: true
    end
    with_short_lock_timeout do
      add_foreign_key :captain_knowledge_grants, :captain_assistants, column: :assistant_id,
                                                                 on_delete: :cascade, validate: false, if_not_exists: true
    end
    return if check_constraint_exists?(:captain_knowledge_grants, name: 'captain_knowledge_grants_record_type')

    with_short_lock_timeout do
      add_check_constraint :captain_knowledge_grants,
                           "knowledge_record_type IN ('Captain::Document', 'Captain::AssistantResponse')",
                           name: 'captain_knowledge_grants_record_type', validate: false
    end
  end

  def backfill_converted_agent_access
    return unless column_exists?(:captain_assistants, :legacy_scenario_id)

    KNOWLEDGE_TABLES.each { |table, record_type| backfill_table_access(table, record_type) }
  end

  def backfill_table_access(table, record_type)
    last_assistant_id = last_record_id = 0
    loop do
      rows = select_rows <<~SQL.squish
        WITH batch AS (
          SELECT converted.account_id, converted.id AS assistant_id, material.id AS knowledge_record_id
          FROM captain_assistants converted
          INNER JOIN captain_scenarios scenario ON scenario.id = converted.legacy_scenario_id AND scenario.account_id = converted.account_id
          INNER JOIN #{table} material ON material.assistant_id = scenario.assistant_id
            AND material.account_id = converted.account_id AND material.visibility = 1
          WHERE converted.id <> scenario.assistant_id
            AND (converted.id, material.id) > (#{last_assistant_id}, #{last_record_id})
          ORDER BY converted.id, material.id LIMIT #{BATCH_SIZE}
        ), inserted AS (
          INSERT INTO captain_knowledge_grants
            (account_id, assistant_id, knowledge_record_type, knowledge_record_id, created_at, updated_at)
          SELECT account_id, assistant_id, '#{record_type}', knowledge_record_id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM batch
          ON CONFLICT (knowledge_record_type, knowledge_record_id, assistant_id) DO NOTHING RETURNING id
        )
        SELECT assistant_id, knowledge_record_id FROM batch ORDER BY assistant_id DESC, knowledge_record_id DESC LIMIT 1
      SQL
      break if rows.empty?

      last_assistant_id, last_record_id = rows.first.map(&:to_i)
    end
  end

  def validate_constraints
    connection.foreign_keys(:captain_knowledge_grants).each do |constraint|
      validate_foreign_key :captain_knowledge_grants, name: constraint.name unless constraint.validated?
    end
    constraint = connection.check_constraints(:captain_knowledge_grants).find { |check| check.name == 'captain_knowledge_grants_record_type' }
    validate_check_constraint :captain_knowledge_grants, name: constraint.name unless constraint.validate?
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
