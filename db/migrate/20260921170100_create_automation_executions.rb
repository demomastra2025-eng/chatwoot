# rubocop:disable Metrics/ClassLength
class CreateAutomationExecutions < ActiveRecord::Migration[7.1]
  STATUSES = %w[pending scheduled processing retrying succeeded cancelled needs_attention].freeze
  IMMUTABLE_COLUMNS = %w[
    account_id automation_event_id automation_rule_id automation_rule_group_id lifecycle_generation definition_version schema_version
    conditions_snapshot actions_snapshot execution_schedule_snapshot scheduled_at created_at
  ].freeze
  IMMUTABILITY_TRIGGER_SQL = <<~SQL.squish.freeze
    CREATE FUNCTION prevent_automation_execution_snapshot_changes()
    RETURNS trigger AS $$
    BEGIN
      IF %<columns>s THEN
        RAISE EXCEPTION 'automation execution snapshot is immutable' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;

    CREATE TRIGGER prevent_automation_execution_snapshot_changes
    BEFORE UPDATE ON automation_executions
    FOR EACH ROW
    EXECUTE FUNCTION prevent_automation_execution_snapshot_changes();
  SQL
  INSERT_CONTRACT_TRIGGER_SQL = <<~SQL.squish.freeze
    CREATE FUNCTION validate_automation_execution_insert_contract()
    RETURNS trigger AS $$
    DECLARE
      selected_group_id bigint;
    BEGIN
      SELECT automation_rule_group_id
      INTO selected_group_id
      FROM automation_rules
      WHERE account_id = NEW.account_id AND id = NEW.automation_rule_id;

      IF FOUND AND NEW.automation_rule_group_id IS DISTINCT FROM selected_group_id THEN
        RAISE EXCEPTION 'automation execution group must match selected rule group' USING ERRCODE = 'check_violation';
      END IF;
      IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(NEW.actions_snapshot) action
        WHERE jsonb_typeof(action) <> 'object'
      ) THEN
        RAISE EXCEPTION 'automation execution actions must be objects' USING ERRCODE = 'check_violation';
      END IF;
      IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(NEW.actions_snapshot) action
        WHERE action ? 'action_id'
          AND (jsonb_typeof(action -> 'action_id') <> 'string' OR btrim(action ->> 'action_id') = '')
      ) THEN
        RAISE EXCEPTION 'automation execution explicit action ids must be non-blank strings' USING ERRCODE = 'check_violation';
      END IF;
      IF (
        SELECT count(action ->> 'action_id') <> count(DISTINCT action ->> 'action_id')
        FROM jsonb_array_elements(NEW.actions_snapshot) action
        WHERE action ? 'action_id'
      ) THEN
        RAISE EXCEPTION 'automation execution explicit action ids must be unique' USING ERRCODE = 'unique_violation';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;

    CREATE TRIGGER validate_automation_execution_insert_contract
    BEFORE INSERT ON automation_executions
    FOR EACH ROW
    EXECUTE FUNCTION validate_automation_execution_insert_contract();
  SQL

  def up
    create_automation_executions
    add_indexes
    add_constraints
    add_account_consistent_foreign_keys
    create_insert_contract_trigger
    create_immutability_trigger
  end

  def down
    execute 'DROP TRIGGER IF EXISTS validate_automation_execution_insert_contract ON automation_executions'
    execute 'DROP FUNCTION IF EXISTS validate_automation_execution_insert_contract()'
    execute 'DROP TRIGGER IF EXISTS prevent_automation_execution_snapshot_changes ON automation_executions'
    execute 'DROP FUNCTION IF EXISTS prevent_automation_execution_snapshot_changes()'
    drop_table :automation_executions
  end

  private

  def create_automation_executions # rubocop:disable Metrics/MethodLength
    create_table :automation_executions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :automation_event, null: false, foreign_key: true
      t.references :automation_rule, null: false, foreign_key: true
      t.references :automation_rule_group, foreign_key: true
      t.bigint :lifecycle_generation, null: false
      t.bigint :definition_version, null: false
      t.integer :schema_version, null: false, default: 1
      t.jsonb :conditions_snapshot, null: false
      t.jsonb :actions_snapshot, null: false
      t.jsonb :execution_schedule_snapshot, null: false
      t.datetime :scheduled_at, null: false
      t.string :status, null: false, default: 'pending'
      t.integer :attempts, null: false, default: 0
      t.string :lease_owner
      t.datetime :lease_expires_at
      t.datetime :next_attempt_at, null: false, default: -> { 'CURRENT_TIMESTAMP' }
      t.text :last_error
      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :needs_attention_at
      t.timestamps
    end
  end

  def add_indexes # rubocop:disable Metrics/MethodLength
    add_index :automation_executions, [:account_id, :id], unique: true, name: 'idx_automation_executions_on_account_and_id'
    add_index :automation_executions,
              [:automation_event_id, :automation_rule_id, :lifecycle_generation],
              unique: true,
              name: 'idx_automation_executions_on_event_rule_generation'
    add_index :automation_executions,
              [:automation_event_id, :automation_rule_group_id],
              unique: true,
              where: 'automation_rule_group_id IS NOT NULL',
              name: 'idx_automation_executions_on_event_group_selection'
    add_index :automation_executions,
              [:next_attempt_at, :id],
              where: "status IN ('pending', 'scheduled', 'retrying')",
              name: 'idx_automation_executions_ready'
    add_index :automation_executions,
              [:lease_expires_at, :id],
              where: "status = 'processing'",
              name: 'idx_automation_executions_expired_lease'
    add_index :automation_executions,
              [:account_id, :status, :created_at, :id],
              name: 'idx_automation_executions_history'
  end

  def add_constraints # rubocop:disable Metrics/MethodLength
    add_check_constraint :automation_executions,
                         "status IN (#{quoted_list(STATUSES)})",
                         name: 'automation_executions_supported_status'
    add_check_constraint :automation_executions, 'attempts >= 0', name: 'automation_executions_non_negative_attempts'
    add_check_constraint :automation_executions, 'lifecycle_generation > 0', name: 'automation_executions_positive_generation'
    add_check_constraint :automation_executions, 'definition_version > 0', name: 'automation_executions_positive_definition_version'
    add_check_constraint :automation_executions, 'schema_version > 0', name: 'automation_executions_positive_schema_version'
    add_check_constraint :automation_executions,
                         "jsonb_typeof(conditions_snapshot) = 'array'",
                         name: 'automation_executions_array_conditions_snapshot'
    add_check_constraint :automation_executions,
                         "jsonb_typeof(actions_snapshot) = 'array' AND jsonb_array_length(actions_snapshot) > 0",
                         name: 'automation_executions_non_blank_array_actions_snapshot'
    add_check_constraint :automation_executions,
                         "jsonb_typeof(execution_schedule_snapshot) = 'object'",
                         name: 'automation_executions_object_schedule_snapshot'
    add_check_constraint :automation_executions,
                         "(status = 'processing' AND lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL) OR " \
                         "(status <> 'processing' AND lease_owner IS NULL AND lease_expires_at IS NULL)",
                         name: 'automation_executions_status_lease_coherence'
    add_check_constraint :automation_executions,
                         "(status = 'needs_attention' AND needs_attention_at IS NOT NULL) OR " \
                         "(status <> 'needs_attention' AND needs_attention_at IS NULL)",
                         name: 'automation_executions_attention_state'
  end

  def add_account_consistent_foreign_keys
    add_foreign_key :automation_executions,
                    :automation_events,
                    column: [:account_id, :automation_event_id],
                    primary_key: [:account_id, :id],
                    name: 'fk_automation_executions_event_account'
    add_foreign_key :automation_executions,
                    :automation_rules,
                    column: [:account_id, :automation_rule_id],
                    primary_key: [:account_id, :id],
                    name: 'fk_automation_executions_rule_account'
    add_foreign_key :automation_executions,
                    :automation_rule_groups,
                    column: [:account_id, :automation_rule_group_id],
                    primary_key: [:account_id, :id],
                    name: 'fk_automation_executions_group_account'
  end

  def create_immutability_trigger
    columns = IMMUTABLE_COLUMNS.map { |column| "NEW.#{column} IS DISTINCT FROM OLD.#{column}" }.join(' OR ')
    execute format(IMMUTABILITY_TRIGGER_SQL, columns: columns)
  end

  def create_insert_contract_trigger
    execute INSERT_CONTRACT_TRIGGER_SQL
  end

  def quoted_list(values)
    values.map { |value| connection.quote(value) }.join(', ')
  end
end
# rubocop:enable Metrics/ClassLength
