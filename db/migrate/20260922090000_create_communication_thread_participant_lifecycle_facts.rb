class CreateCommunicationThreadParticipantLifecycleFacts < ActiveRecord::Migration[7.1]
  ACTIONS = %w[add remove clear retain promote resolve].freeze
  ACTOR_KINDS = %w[system user customer captain automation].freeze

  def up
    create_facts_table
    add_indexes
    add_checks
    create_insert_contract_trigger
    create_immutability_trigger
  end

  def down
    execute 'DROP TRIGGER IF EXISTS validate_thread_participant_fact_insert ON communication_thread_participant_lifecycle_facts'
    execute 'DROP FUNCTION IF EXISTS validate_thread_participant_fact_insert()'
    execute 'DROP TRIGGER IF EXISTS prevent_thread_participant_fact_changes ON communication_thread_participant_lifecycle_facts'
    execute 'DROP FUNCTION IF EXISTS prevent_thread_participant_fact_changes()'
    drop_table :communication_thread_participant_lifecycle_facts
  end

  private

  def create_facts_table
    create_table :communication_thread_participant_lifecycle_facts do |t|
      t.references :account, null: false, foreign_key: true
      t.bigint :communication_thread_id, null: false
      t.string :participant_type, null: false, default: 'User'
      t.bigint :participant_id, null: false
      t.string :actor_kind, null: false
      t.string :actor_type, null: false
      t.bigint :actor_id
      t.string :action, null: false
      t.string :reason, null: false
      t.datetime :occurred_at, null: false
      t.datetime :reliable_since
      t.uuid :correlation_id, null: false
      t.string :idempotency_key, null: false
      t.integer :schema_version, null: false, default: 1
      t.datetime :created_at, null: false
    end
  end

  def add_indexes
    add_index :communication_thread_participant_lifecycle_facts,
              [:account_id, :idempotency_key],
              unique: true,
              name: 'idx_thread_participant_facts_idempotency'
    add_index :communication_thread_participant_lifecycle_facts,
              [:account_id, :communication_thread_id, :occurred_at, :id],
              name: 'idx_thread_participant_facts_thread_time'
    add_index :communication_thread_participant_lifecycle_facts,
              [:account_id, :participant_id, :occurred_at, :id],
              name: 'idx_thread_participant_facts_participant_time'
    add_index :communication_thread_participant_lifecycle_facts,
              [:account_id, :action, :occurred_at, :id],
              name: 'idx_thread_participant_facts_action_time'
  end

  def add_checks # rubocop:disable Metrics/MethodLength
    add_check_constraint :communication_thread_participant_lifecycle_facts,
                         "action IN (#{quoted_values(ACTIONS)})",
                         name: 'chk_thread_participant_facts_action'
    add_check_constraint :communication_thread_participant_lifecycle_facts,
                         "actor_kind IN (#{quoted_values(ACTOR_KINDS)})",
                         name: 'chk_thread_participant_facts_actor_kind'
    add_check_constraint :communication_thread_participant_lifecycle_facts,
                         "participant_type = 'User'",
                         name: 'chk_thread_participant_facts_participant_type'
    add_check_constraint :communication_thread_participant_lifecycle_facts,
                         'schema_version = 1',
                         name: 'chk_thread_participant_facts_schema_version'
    add_check_constraint :communication_thread_participant_lifecycle_facts,
                         "(actor_kind = 'system' AND actor_id IS NULL) OR (actor_kind <> 'system' AND actor_id IS NOT NULL)",
                         name: 'chk_thread_participant_facts_actor_identity'
    add_check_constraint :communication_thread_participant_lifecycle_facts,
                         "(actor_kind = 'system' AND actor_type = 'System') OR " \
                         "(actor_kind = 'user' AND actor_type = 'User') OR " \
                         "(actor_kind = 'customer' AND actor_type = 'Contact') OR " \
                         "(actor_kind = 'captain' AND actor_type = 'Captain::Assistant') OR " \
                         "(actor_kind = 'automation' AND actor_type IN ('AssignmentPolicy', 'AutomationRule', 'Inbox'))",
                         name: 'chk_thread_participant_facts_actor_type'
    add_check_constraint :communication_thread_participant_lifecycle_facts,
                         'reliable_since IS NULL OR reliable_since <= occurred_at',
                         name: 'chk_thread_participant_facts_reliable_since'
  end

  def create_insert_contract_trigger # rubocop:disable Metrics/MethodLength
    execute <<~SQL.squish
      CREATE FUNCTION validate_thread_participant_fact_insert()
      RETURNS trigger AS $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM communication_threads
          WHERE id = NEW.communication_thread_id AND account_id = NEW.account_id
        ) THEN
          RAISE EXCEPTION 'participant fact thread must belong to account' USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM account_users
          WHERE account_id = NEW.account_id AND user_id = NEW.participant_id
        ) THEN
          RAISE EXCEPTION 'participant fact user must belong to account' USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF NEW.actor_kind = 'user' AND NOT EXISTS (
          SELECT 1 FROM account_users WHERE account_id = NEW.account_id AND user_id = NEW.actor_id
        ) THEN
          RAISE EXCEPTION 'participant fact user actor must belong to account' USING ERRCODE = 'foreign_key_violation';
        ELSIF NEW.actor_kind = 'customer' AND NOT EXISTS (
          SELECT 1 FROM contacts WHERE account_id = NEW.account_id AND id = NEW.actor_id
        ) THEN
          RAISE EXCEPTION 'participant fact customer actor must belong to account' USING ERRCODE = 'foreign_key_violation';
        ELSIF NEW.actor_kind = 'captain' AND NOT EXISTS (
          SELECT 1 FROM captain_assistants WHERE account_id = NEW.account_id AND id = NEW.actor_id
        ) THEN
          RAISE EXCEPTION 'participant fact captain actor must belong to account' USING ERRCODE = 'foreign_key_violation';
        ELSIF NEW.actor_kind = 'automation' AND (
          (NEW.actor_type = 'AssignmentPolicy' AND NOT EXISTS (
            SELECT 1 FROM assignment_policies WHERE account_id = NEW.account_id AND id = NEW.actor_id
          )) OR
          (NEW.actor_type = 'AutomationRule' AND NOT EXISTS (
            SELECT 1 FROM automation_rules WHERE account_id = NEW.account_id AND id = NEW.actor_id
          )) OR
          (NEW.actor_type = 'Inbox' AND NOT EXISTS (
            SELECT 1 FROM inboxes WHERE account_id = NEW.account_id AND id = NEW.actor_id
          )) OR
          NEW.actor_type NOT IN ('AssignmentPolicy', 'AutomationRule', 'Inbox')
        ) THEN
          RAISE EXCEPTION 'participant fact automation actor must belong to account' USING ERRCODE = 'foreign_key_violation';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER validate_thread_participant_fact_insert
      BEFORE INSERT ON communication_thread_participant_lifecycle_facts
      FOR EACH ROW
      EXECUTE FUNCTION validate_thread_participant_fact_insert();
    SQL
  end

  def create_immutability_trigger
    execute <<~SQL.squish
      CREATE FUNCTION prevent_thread_participant_fact_changes()
      RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' AND
           current_setting('onelink.account_teardown_id', true) = OLD.account_id::text THEN
          RETURN OLD;
        END IF;

        RAISE EXCEPTION 'communication thread participant lifecycle facts are append-only' USING ERRCODE = 'check_violation';
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER prevent_thread_participant_fact_changes
      BEFORE UPDATE OR DELETE ON communication_thread_participant_lifecycle_facts
      FOR EACH ROW
      EXECUTE FUNCTION prevent_thread_participant_fact_changes();
    SQL
  end

  def quoted_values(values)
    values.map { |value| connection.quote(value) }.join(', ')
  end
end
