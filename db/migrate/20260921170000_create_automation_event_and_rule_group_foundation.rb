# rubocop:disable Metrics/ClassLength
class CreateAutomationEventAndRuleGroupFoundation < ActiveRecord::Migration[7.1]
  EVENT_STATUSES = %w[pending processing retrying completed dead].freeze
  IMMUTABLE_EVENT_COLUMNS = %w[
    account_id event_uuid dedupe_key event_name subject_type subject_id schema_version payload_snapshot changes_snapshot producer provenance
    trace_id causation_id depth created_at
  ].freeze
  RULE_DEFINITION_TRIGGER_SQL = <<~SQL.squish.freeze
    CREATE FUNCTION bump_automation_rule_definition_version()
    RETURNS trigger AS $$
    BEGIN
      IF (
        NEW.event_name IS DISTINCT FROM OLD.event_name OR
        NEW.conditions IS DISTINCT FROM OLD.conditions OR
        NEW.actions IS DISTINCT FROM OLD.actions OR
        NEW.execution_schedule IS DISTINCT FROM OLD.execution_schedule OR
        NEW.automation_rule_group_id IS DISTINCT FROM OLD.automation_rule_group_id OR
        NEW.position IS DISTINCT FROM OLD.position
      ) AND NEW.definition_version <= OLD.definition_version THEN
        NEW.definition_version := OLD.definition_version + 1;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;

    CREATE TRIGGER bump_automation_rule_definition_version
    BEFORE UPDATE ON automation_rules
    FOR EACH ROW
    EXECUTE FUNCTION bump_automation_rule_definition_version();
  SQL
  EVENT_IMMUTABILITY_TRIGGER_SQL = <<~SQL.squish.freeze
    CREATE FUNCTION prevent_automation_event_envelope_changes()
    RETURNS trigger AS $$
    BEGIN
      IF %<columns>s THEN
        RAISE EXCEPTION 'automation event envelope is immutable' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;

    CREATE TRIGGER prevent_automation_event_envelope_changes
    BEFORE UPDATE ON automation_events
    FOR EACH ROW
    EXECUTE FUNCTION prevent_automation_event_envelope_changes();
  SQL
  EVENT_CAUSATION_TRIGGER_SQL = <<~SQL.squish.freeze
    CREATE FUNCTION validate_automation_event_causation()
    RETURNS trigger AS $$
    DECLARE
      parent_trace_id uuid;
      parent_depth integer;
    BEGIN
      IF NEW.causation_id IS NULL THEN
        IF NEW.depth <> 0 THEN
          RAISE EXCEPTION 'root automation event depth must be zero' USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END IF;

      SELECT trace_id, depth
      INTO parent_trace_id, parent_depth
      FROM automation_events
      WHERE account_id = NEW.account_id AND event_uuid = NEW.causation_id;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'automation event causation parent does not exist in account' USING ERRCODE = 'foreign_key_violation';
      END IF;
      IF NEW.trace_id IS DISTINCT FROM parent_trace_id OR NEW.depth <> parent_depth + 1 THEN
        RAISE EXCEPTION 'automation event causation must preserve trace and increment depth' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;

    CREATE TRIGGER validate_automation_event_causation
    BEFORE INSERT ON automation_events
    FOR EACH ROW
    EXECUTE FUNCTION validate_automation_event_causation();
  SQL

  def up
    create_automation_rule_groups
    extend_automation_rules
    create_rule_definition_version_trigger
    create_automation_events
    create_event_causation_trigger
    create_event_immutability_trigger
  end

  def down
    drop_event_immutability_trigger
    drop_event_causation_trigger
    drop_table :automation_events
    drop_rule_definition_version_trigger

    remove_foreign_key :automation_rules, name: 'fk_automation_rules_group_account_event'
    remove_check_constraint :automation_rules, name: 'automation_rules_group_position_complete'
    remove_check_constraint :automation_rules, name: 'automation_rules_non_negative_position'
    remove_check_constraint :automation_rules, name: 'automation_rules_positive_definition_version'
    remove_index :automation_rules, name: 'idx_automation_rules_on_group_position'
    remove_index :automation_rules, name: 'idx_automation_rules_runtime_lookup'
    remove_index :automation_rules, name: 'idx_automation_rules_on_account_and_id'
    remove_reference :automation_rules, :automation_rule_group, foreign_key: true
    remove_column :automation_rules, :position
    remove_column :automation_rules, :definition_version

    drop_table :automation_rule_groups
  end

  private

  def create_automation_rule_groups
    create_table :automation_rule_groups do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false
      t.string :event_name, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :automation_rule_groups, [:account_id, :id], unique: true, name: 'idx_automation_rule_groups_on_account_and_id'
    add_index :automation_rule_groups,
              [:account_id, :id, :event_name],
              unique: true,
              name: 'idx_automation_rule_groups_on_account_id_event'
    add_check_constraint :automation_rule_groups, "btrim(name) <> ''", name: 'automation_rule_groups_non_blank_name'
    add_check_constraint :automation_rule_groups, "btrim(event_name) <> ''", name: 'automation_rule_groups_non_blank_event'
  end

  def extend_automation_rules
    add_reference :automation_rules, :automation_rule_group, foreign_key: true
    add_column :automation_rules, :position, :integer
    add_column :automation_rules, :definition_version, :bigint, null: false, default: 1

    add_automation_rule_indexes
    add_automation_rule_constraints
  end

  def add_automation_rule_indexes
    add_index :automation_rules, [:account_id, :id], unique: true, name: 'idx_automation_rules_on_account_and_id'
    add_index :automation_rules,
              [:automation_rule_group_id, :position],
              unique: true,
              where: 'automation_rule_group_id IS NOT NULL',
              name: 'idx_automation_rules_on_group_position'
    add_index :automation_rules,
              [:account_id, :event_name, :active, :automation_rule_group_id, :position, :id],
              name: 'idx_automation_rules_runtime_lookup'
  end

  def add_automation_rule_constraints
    add_check_constraint :automation_rules,
                         '(automation_rule_group_id IS NULL AND position IS NULL) OR ' \
                         '(automation_rule_group_id IS NOT NULL AND position IS NOT NULL)',
                         name: 'automation_rules_group_position_complete'
    add_check_constraint :automation_rules, 'position IS NULL OR position >= 0', name: 'automation_rules_non_negative_position'
    add_check_constraint :automation_rules, 'definition_version > 0', name: 'automation_rules_positive_definition_version'
    add_foreign_key :automation_rules,
                    :automation_rule_groups,
                    column: [:account_id, :automation_rule_group_id, :event_name],
                    primary_key: [:account_id, :id, :event_name],
                    name: 'fk_automation_rules_group_account_event'
  end

  def create_automation_events # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
    create_table :automation_events do |t|
      t.references :account, null: false, foreign_key: true
      t.uuid :event_uuid, null: false, default: -> { 'gen_random_uuid()' }
      t.string :dedupe_key, null: false
      t.string :event_name, null: false
      t.string :subject_type, null: false
      t.bigint :subject_id, null: false
      t.integer :schema_version, null: false, default: 1
      t.jsonb :payload_snapshot, null: false, default: {}
      t.jsonb :changes_snapshot, null: false, default: {}
      t.string :producer, null: false
      t.jsonb :provenance, null: false, default: {}
      t.uuid :trace_id, null: false
      t.uuid :causation_id
      t.integer :depth, null: false, default: 0
      t.string :status, null: false, default: 'pending'
      t.integer :attempts, null: false, default: 0
      t.string :lease_owner
      t.datetime :lease_expires_at
      t.datetime :next_attempt_at, null: false, default: -> { 'CURRENT_TIMESTAMP' }
      t.text :last_error
      t.datetime :dead_at
      t.timestamps
    end

    add_automation_event_indexes
    add_automation_event_constraints
  end

  def add_automation_event_indexes
    add_index :automation_events, [:account_id, :id], unique: true, name: 'idx_automation_events_on_account_and_id'
    add_index :automation_events, :event_uuid, unique: true, name: 'idx_automation_events_on_uuid'
    add_index :automation_events, [:account_id, :event_uuid], unique: true, name: 'idx_automation_events_on_account_uuid'
    add_index :automation_events, [:account_id, :dedupe_key], unique: true, name: 'idx_automation_events_on_account_dedupe'
    add_index :automation_events,
              [:next_attempt_at, :id],
              where: "status IN ('pending', 'retrying')",
              name: 'idx_automation_events_ready'
    add_index :automation_events,
              [:lease_expires_at, :id],
              where: "status = 'processing'",
              name: 'idx_automation_events_expired_lease'
    add_index :automation_events,
              [:account_id, :dead_at, :id],
              where: "status = 'dead'",
              name: 'idx_automation_events_dead'
  end

  def add_automation_event_constraints # rubocop:disable Metrics/MethodLength
    add_check_constraint :automation_events,
                         "status IN (#{quoted_list(EVENT_STATUSES)})",
                         name: 'automation_events_supported_status'
    add_check_constraint :automation_events, 'attempts >= 0', name: 'automation_events_non_negative_attempts'
    add_check_constraint :automation_events, 'schema_version > 0', name: 'automation_events_positive_schema_version'
    add_check_constraint :automation_events, 'depth >= 0', name: 'automation_events_non_negative_depth'
    add_check_constraint :automation_events, "btrim(dedupe_key) <> ''", name: 'automation_events_non_blank_dedupe_key'
    add_check_constraint :automation_events, "btrim(event_name) <> ''", name: 'automation_events_non_blank_event_name'
    add_check_constraint :automation_events, "btrim(subject_type) <> ''", name: 'automation_events_non_blank_subject_type'
    add_check_constraint :automation_events, "btrim(producer) <> ''", name: 'automation_events_non_blank_producer'
    add_check_constraint :automation_events,
                         "jsonb_typeof(payload_snapshot) = 'object' AND payload_snapshot <> '{}'::jsonb",
                         name: 'automation_events_object_payload_snapshot'
    add_check_constraint :automation_events,
                         "jsonb_typeof(changes_snapshot) = 'object'",
                         name: 'automation_events_object_changes_snapshot'
    add_check_constraint :automation_events,
                         "jsonb_typeof(provenance) = 'object' AND provenance <> '{}'::jsonb",
                         name: 'automation_events_non_blank_object_provenance'
    add_check_constraint :automation_events,
                         '(causation_id IS NULL AND depth = 0) OR (causation_id IS NOT NULL AND depth > 0)',
                         name: 'automation_events_causation_depth_shape'
    add_check_constraint :automation_events,
                         "(status = 'processing' AND lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL) OR " \
                         "(status <> 'processing' AND lease_owner IS NULL AND lease_expires_at IS NULL)",
                         name: 'automation_events_status_lease_coherence'
    add_check_constraint :automation_events,
                         "(status = 'dead' AND dead_at IS NOT NULL) OR (status <> 'dead' AND dead_at IS NULL)",
                         name: 'automation_events_complete_dead_state'
    add_foreign_key :automation_events,
                    :automation_events,
                    column: [:account_id, :causation_id],
                    primary_key: [:account_id, :event_uuid],
                    name: 'fk_automation_events_causation_account'
  end

  def create_event_causation_trigger
    execute EVENT_CAUSATION_TRIGGER_SQL
  end

  def drop_event_causation_trigger
    execute 'DROP TRIGGER IF EXISTS validate_automation_event_causation ON automation_events'
    execute 'DROP FUNCTION IF EXISTS validate_automation_event_causation()'
  end

  def create_rule_definition_version_trigger
    execute RULE_DEFINITION_TRIGGER_SQL
  end

  def drop_rule_definition_version_trigger
    execute 'DROP TRIGGER IF EXISTS bump_automation_rule_definition_version ON automation_rules'
    execute 'DROP FUNCTION IF EXISTS bump_automation_rule_definition_version()'
  end

  def create_event_immutability_trigger
    columns = IMMUTABLE_EVENT_COLUMNS.map { |column| "NEW.#{column} IS DISTINCT FROM OLD.#{column}" }.join(' OR ')
    execute format(EVENT_IMMUTABILITY_TRIGGER_SQL, columns: columns)
  end

  def drop_event_immutability_trigger
    execute 'DROP TRIGGER IF EXISTS prevent_automation_event_envelope_changes ON automation_events'
    execute 'DROP FUNCTION IF EXISTS prevent_automation_event_envelope_changes()'
  end

  def quoted_list(values)
    values.map { |value| connection.quote(value) }.join(', ')
  end
end
# rubocop:enable Metrics/ClassLength
