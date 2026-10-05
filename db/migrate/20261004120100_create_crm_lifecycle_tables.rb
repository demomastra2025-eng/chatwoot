class CreateCrmLifecycleTables < ActiveRecord::Migration[7.1]
  # Step 2 of the CRM lifecycle expand. New tables are created WITHOUT foreign keys, so no lock is taken on
  # accounts, users or the CRM tables the old application is writing to; the keys follow as NOT VALID in 20261004120200.
  # Each table is created in its own small transaction (table and indexes together), so an interrupted run never leaves
  # a half-built table behind that the existence guard would then accept. The stage visit indexes are built
  # concurrently after the backfill (20261004120400).
  disable_ddl_transaction!

  LOCK_TIMEOUT = '5s'.freeze
  LOCK_ATTEMPTS = 5
  STAGE_VISIT_REQUIRED_COLUMNS = %w[
    account_id deal_id pipeline_id stage_id entered_at exited_at estimated reliable_since pipeline_name stage_name
    stage_outcome correlation_id created_at updated_at
  ].freeze

  def up
    create_task_types
    create_task_outcomes
    create_stage_field_requirements
    create_stage_visits
    ensure_stage_visit_columns
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'CRM lifecycle schema is additive; roll back application behavior without removing retained CRM data'
  end

  private

  def create_task_types
    return if table_exists?(:crm_task_types)

    transaction do
      create_table :crm_task_types do |t|
        t.references :account, null: false, foreign_key: false
        t.string :name, null: false
        t.string :code, null: false
        t.string :icon, null: false, default: 'i-lucide-list-todo'
        t.integer :position, null: false, default: 0
        t.boolean :active, null: false, default: true
        t.boolean :default, null: false, default: false
        t.timestamps
      end
      add_index :crm_task_types, %i[account_id code], unique: true
      add_index :crm_task_types, :account_id, unique: true,
                                              where: '"default" = TRUE AND active = TRUE',
                                              name: 'index_crm_task_types_on_account_default'
    end
  end

  def create_task_outcomes
    return if table_exists?(:crm_task_outcomes)

    transaction do
      create_table :crm_task_outcomes do |t|
        t.references :account, null: false, foreign_key: false
        t.references :task_type, null: false, foreign_key: false
        t.string :name, null: false
        t.string :code, null: false
        t.integer :position, null: false, default: 0
        t.boolean :active, null: false, default: true
        t.boolean :default, null: false, default: false
        t.boolean :requires_note, null: false, default: false
        t.timestamps
      end
      add_index :crm_task_outcomes, %i[task_type_id code], unique: true
      add_index :crm_task_outcomes, %i[account_id task_type_id]
      add_index :crm_task_outcomes, :task_type_id, unique: true,
                                                   where: '"default" = TRUE AND active = TRUE',
                                                   name: 'index_crm_task_outcomes_on_type_default'
    end
  end

  def create_stage_field_requirements
    return if table_exists?(:crm_stage_field_requirements)

    transaction do
      create_table :crm_stage_field_requirements do |t|
        t.references :account, null: false, foreign_key: false
        t.references :stage, null: false, foreign_key: false
        t.references :field_definition, null: true, foreign_key: false
        t.string :field_key, null: false
        t.boolean :required, null: false, default: true
        t.jsonb :validation, null: false, default: {}
        t.jsonb :role_exemptions, null: false, default: []
        t.timestamps
      end
      add_index :crm_stage_field_requirements, %i[stage_id field_key], unique: true,
                                                                       name: 'index_crm_stage_requirements_on_stage_and_field'
      add_index :crm_stage_field_requirements, %i[account_id stage_id],
                name: 'index_crm_stage_requirements_on_account_and_stage'
    end
  end

  def create_stage_visits
    return if table_exists?(:crm_stage_visits)

    transaction do
      create_table :crm_stage_visits do |t|
        define_stage_visit_columns(t)
        t.timestamps
      end
    end
  end

  def define_stage_visit_columns(table)
    table.references :account, null: false, foreign_key: false, index: false
    table.references :deal, null: false, foreign_key: false, index: false
    table.references :pipeline, null: false, foreign_key: false, index: false
    table.references :stage, null: false, foreign_key: false, index: false
    table.datetime :entered_at, null: false
    table.datetime :exited_at
    table.boolean :estimated, null: false, default: false
    table.datetime :reliable_since, null: false
    table.string :pipeline_name, null: false
    table.string :stage_name, null: false
    table.string :stage_outcome, null: false
    table.uuid :correlation_id, null: false, default: -> { 'gen_random_uuid()' }
    table.bigint :owner_id_at_terminal
    table.bigint :team_id_at_terminal
    table.integer :terminal_attribution_version
  end

  # A crm_stage_visits table that already exists (the aset lineage) keeps its shape and data: only the attribution
  # columns and the UUID generator that the new code relies on are repaired, as metadata changes.
  def ensure_stage_visit_columns
    missing = STAGE_VISIT_REQUIRED_COLUMNS - connection.columns(:crm_stage_visits).map(&:name)
    if missing.any?
      raise ActiveRecord::MigrationError,
            "Existing crm_stage_visits is missing required columns: #{missing.join(', ')}"
    end

    with_short_lock_timeout do
      add_stage_visit_attribution_columns
      ensure_stage_visit_uuid_default
    end
  end

  def add_stage_visit_attribution_columns
    add_column :crm_stage_visits, :owner_id_at_terminal, :bigint, if_not_exists: true
    add_column :crm_stage_visits, :team_id_at_terminal, :bigint, if_not_exists: true
    add_column :crm_stage_visits, :terminal_attribution_version, :integer, if_not_exists: true
  end

  def ensure_stage_visit_uuid_default
    correlation_id_column = connection.columns(:crm_stage_visits).find do |column|
      column.name == 'correlation_id'
    end
    raise 'crm_stage_visits.correlation_id is missing' unless correlation_id_column

    actual_uuid_defaults = [correlation_id_column.default, correlation_id_column.default_function]
    has_expected_uuid_default = actual_uuid_defaults.include?('gen_random_uuid()')
    has_no_uuid_default = actual_uuid_defaults.all?(&:nil?)
    if has_no_uuid_default
      change_column_default(:crm_stage_visits, :correlation_id, -> { 'gen_random_uuid()' })
    elsif !has_expected_uuid_default
      raise "Unexpected crm_stage_visits.correlation_id default: #{actual_uuid_defaults.inspect}"
    end
  end

  def with_short_lock_timeout
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
