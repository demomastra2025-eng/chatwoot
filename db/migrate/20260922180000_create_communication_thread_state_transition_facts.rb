class CreateCommunicationThreadStateTransitionFacts < ActiveRecord::Migration[7.1] # rubocop:disable Metrics/ClassLength
  EVENT_KINDS = %w[created routing_changed resolved reopened state_changed].freeze
  ACTOR_KINDS = %w[user contact captain system automation unknown].freeze

  def up
    create_facts_table
    add_indexes
    add_checks
    normalize_orphaned_assignments
    # Fence late Conversation joins while Team deletion writes Thread facts.
    # Legacy orphaned team IDs remain unverified; all new references are checked.
    add_foreign_key :conversations, :teams,
                    name: 'fk_conversations_team_for_thread_state_facts', on_delete: :nullify, validate: false
    create_insert_contract_trigger
    create_projection_fallback_trigger
    create_membership_deletion_trigger
    create_immutability_trigger
  end

  def down
    remove_foreign_key :conversations, name: 'fk_conversations_team_for_thread_state_facts'
    execute 'DROP TRIGGER IF EXISTS clear_thread_routing_before_account_user_delete ON account_users'
    execute 'DROP FUNCTION IF EXISTS clear_thread_routing_before_account_user_delete()'
    execute 'DROP TRIGGER IF EXISTS record_thread_state_transition_fallback ON communication_threads'
    execute 'DROP FUNCTION IF EXISTS record_thread_state_transition_fallback()'
    execute 'DROP TRIGGER IF EXISTS validate_thread_state_transition_fact_insert ON communication_thread_state_transition_facts'
    execute 'DROP FUNCTION IF EXISTS validate_thread_state_transition_fact_insert()'
    execute 'DROP TRIGGER IF EXISTS prevent_thread_state_transition_fact_changes ON communication_thread_state_transition_facts'
    execute 'DROP FUNCTION IF EXISTS prevent_thread_state_transition_fact_changes()'
    drop_table :communication_thread_state_transition_facts
  end

  private

  def normalize_orphaned_assignments
    # Historical membership is unavailable: remove projections we cannot attribute before fact capture starts.
    %w[contacts conversations communication_threads].each do |table|
      column = table == 'contacts' ? 'owner_id' : 'assignee_id'
      execute <<~SQL.squish
        UPDATE #{table} AS record SET #{column} = NULL
        WHERE #{column} IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM account_users WHERE account_id = record.account_id AND user_id = record.#{column}
        )
      SQL
    end
  end

  def create_membership_deletion_trigger
    execute <<~SQL.squish
      CREATE FUNCTION clear_thread_routing_before_account_user_delete()
      RETURNS trigger AS $$
      BEGIN
        IF current_setting('onelink.account_teardown_id', true) = OLD.account_id::text THEN
          RETURN OLD;
        END IF;
        UPDATE contacts SET owner_id = NULL WHERE account_id = OLD.account_id AND owner_id = OLD.user_id;
        UPDATE conversations SET assignee_id = NULL WHERE account_id = OLD.account_id AND assignee_id = OLD.user_id;
        UPDATE communication_threads SET assignee_id = NULL
        WHERE account_id = OLD.account_id AND assignee_id = OLD.user_id;
        RETURN OLD;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER clear_thread_routing_before_account_user_delete
      BEFORE DELETE ON account_users
      FOR EACH ROW
      EXECUTE FUNCTION clear_thread_routing_before_account_user_delete();
    SQL
  end

  def create_facts_table # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    create_table :communication_thread_state_transition_facts do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, index: true
      t.bigint :communication_thread_id_snapshot, null: false
      t.bigint :thread_display_id_snapshot, null: false
      t.bigint :contact_id_snapshot, null: false
      t.string :event_kind, null: false
      t.datetime :occurred_at, null: false
      t.datetime :requested_occurred_at, null: false
      t.datetime :reliable_since, null: false
      t.integer :source_version, null: false, default: 1
      t.string :request_fingerprint, limit: 64
      t.bigint :from_assignee_id
      t.string :from_assignee_name
      t.bigint :to_assignee_id
      t.string :to_assignee_name
      t.bigint :from_team_id
      t.string :from_team_name
      t.bigint :to_team_id
      t.string :to_team_name
      t.string :from_status
      t.string :to_status, null: false
      t.string :source, null: false
      t.string :source_record_type
      t.bigint :source_record_id
      t.uuid :source_event_id, null: false
      t.string :actor_kind, null: false
      t.bigint :actor_id
      t.string :actor_name
      t.string :idempotency_key, null: false
      t.datetime :created_at, null: false
    end
  end

  def add_indexes
    add_index :communication_thread_state_transition_facts,
              [:account_id, :idempotency_key],
              unique: true, name: 'idx_thread_state_facts_idempotency'
    add_index :communication_thread_state_transition_facts,
              [:account_id, :occurred_at, :id],
              name: 'idx_thread_state_facts_account_time'
    add_index :communication_thread_state_transition_facts,
              [:account_id, :communication_thread_id_snapshot, :occurred_at, :id],
              name: 'idx_thread_state_facts_thread_time'
    add_index :communication_thread_state_transition_facts,
              [:account_id, :to_assignee_id, :occurred_at, :id],
              name: 'idx_thread_state_facts_assignee_time'
    add_index :communication_thread_state_transition_facts,
              [:account_id, :to_team_id, :occurred_at, :id],
              name: 'idx_thread_state_facts_team_time'
    add_index :communication_thread_state_transition_facts,
              [:account_id, :event_kind, :occurred_at, :id],
              name: 'idx_thread_state_facts_kind_time'
  end

  def add_checks # rubocop:disable Metrics/MethodLength
    add_check_constraint :communication_thread_state_transition_facts,
                         "event_kind IN (#{quoted_values(EVENT_KINDS)})",
                         name: 'chk_thread_state_facts_event_kind'
    add_check_constraint :communication_thread_state_transition_facts,
                         "actor_kind IN (#{quoted_values(ACTOR_KINDS)})",
                         name: 'chk_thread_state_facts_actor_kind'
    add_check_constraint :communication_thread_state_transition_facts,
                         'source_version = 1',
                         name: 'chk_thread_state_facts_source_version'
    add_check_constraint :communication_thread_state_transition_facts,
                         "(source = 'database_projection_fallback' AND request_fingerprint IS NULL) OR " \
                         "(source <> 'database_projection_fallback' AND request_fingerprint IS NOT NULL AND " \
                         "request_fingerprint ~ '^[0-9a-f]{64}$')",
                         name: 'chk_thread_state_facts_request_fingerprint'
    add_check_constraint :communication_thread_state_transition_facts,
                         "btrim(source) <> '' AND btrim(idempotency_key) <> ''",
                         name: 'chk_thread_state_facts_nonblank_identity'
    add_check_constraint :communication_thread_state_transition_facts,
                         'reliable_since <= occurred_at',
                         name: 'chk_thread_state_facts_reliable_since'
    add_check_constraint :communication_thread_state_transition_facts,
                         'requested_occurred_at <= occurred_at',
                         name: 'chk_thread_state_facts_requested_occurred_at'
    add_check_constraint :communication_thread_state_transition_facts,
                         "(actor_kind IN ('system', 'unknown') AND actor_id IS NULL) OR " \
                         "(actor_kind IN ('user', 'contact', 'captain', 'automation') AND actor_id IS NOT NULL)",
                         name: 'chk_thread_state_facts_actor_identity'
    add_check_constraint :communication_thread_state_transition_facts,
                         '(source_record_type IS NULL) = (source_record_id IS NULL)',
                         name: 'chk_thread_state_facts_source_record'
    add_check_constraint :communication_thread_state_transition_facts,
                         "(event_kind = 'created' AND from_assignee_id IS NULL AND from_team_id IS NULL AND from_status IS NULL) OR " \
                         "(event_kind <> 'created' AND from_status IS NOT NULL AND " \
                         '(from_assignee_id IS DISTINCT FROM to_assignee_id OR from_team_id IS DISTINCT FROM to_team_id OR ' \
                         'from_status IS DISTINCT FROM to_status))',
                         name: 'chk_thread_state_facts_effective_change'
    add_check_constraint :communication_thread_state_transition_facts,
                         "event_kind <> 'resolved' OR (from_status <> 'resolved' AND to_status = 'resolved')",
                         name: 'chk_thread_state_facts_resolved'
    add_check_constraint :communication_thread_state_transition_facts,
                         "event_kind <> 'reopened' OR (from_status = 'resolved' AND to_status <> 'resolved')",
                         name: 'chk_thread_state_facts_reopened'
    add_check_constraint :communication_thread_state_transition_facts,
                         "event_kind <> 'routing_changed' OR " \
                         '(from_assignee_id IS DISTINCT FROM to_assignee_id OR from_team_id IS DISTINCT FROM to_team_id)',
                         name: 'chk_thread_state_facts_routing_changed'
  end

  def create_insert_contract_trigger # rubocop:disable Metrics/MethodLength
    execute <<~SQL.squish
      CREATE FUNCTION validate_thread_state_transition_fact_insert()
      RETURNS trigger AS $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM communication_threads
          WHERE id = NEW.communication_thread_id_snapshot
            AND account_id = NEW.account_id
            AND contact_id = NEW.contact_id_snapshot
            AND display_id = NEW.thread_display_id_snapshot
        ) THEN
          RAISE EXCEPTION 'thread state fact snapshot must match its account thread' USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM contacts WHERE id = NEW.contact_id_snapshot AND account_id = NEW.account_id
        ) THEN
          RAISE EXCEPTION 'thread state fact contact snapshot must belong to account' USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF NEW.from_assignee_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM account_users WHERE account_id = NEW.account_id AND user_id = NEW.from_assignee_id
        ) THEN
          RAISE EXCEPTION 'thread state fact from assignee must belong to account' USING ERRCODE = 'foreign_key_violation';
        ELSIF NEW.to_assignee_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM account_users WHERE account_id = NEW.account_id AND user_id = NEW.to_assignee_id
        ) THEN
          RAISE EXCEPTION 'thread state fact to assignee must belong to account' USING ERRCODE = 'foreign_key_violation';
        ELSIF NEW.from_team_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM teams WHERE account_id = NEW.account_id AND id = NEW.from_team_id
        ) THEN
          RAISE EXCEPTION 'thread state fact from team must belong to account' USING ERRCODE = 'foreign_key_violation';
        ELSIF NEW.to_team_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM teams WHERE account_id = NEW.account_id AND id = NEW.to_team_id
        ) THEN
          RAISE EXCEPTION 'thread state fact to team must belong to account' USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF NEW.source_record_type = 'Contact' AND NOT EXISTS (
          SELECT 1 FROM contacts WHERE account_id = NEW.account_id AND id = NEW.source_record_id
        ) THEN
          RAISE EXCEPTION 'thread state fact source contact must belong to account' USING ERRCODE = 'foreign_key_violation';
        ELSIF NEW.source_record_type = 'Conversation' AND NOT EXISTS (
          SELECT 1 FROM conversations WHERE account_id = NEW.account_id AND id = NEW.source_record_id
        ) THEN
          RAISE EXCEPTION 'thread state fact source conversation must belong to account' USING ERRCODE = 'foreign_key_violation';
        ELSIF NEW.source_record_type = 'CommunicationThread' AND NOT EXISTS (
          SELECT 1 FROM communication_threads WHERE account_id = NEW.account_id AND id = NEW.source_record_id
        ) THEN
          RAISE EXCEPTION 'thread state fact source thread must belong to account' USING ERRCODE = 'foreign_key_violation';
        ELSIF NEW.source_record_type = 'Team' AND NOT EXISTS (
          SELECT 1 FROM teams WHERE account_id = NEW.account_id AND id = NEW.source_record_id
        ) THEN
          RAISE EXCEPTION 'thread state fact source team must belong to account' USING ERRCODE = 'foreign_key_violation';
        ELSIF NEW.source_record_type = 'AssignmentPolicy' AND NOT EXISTS (
          SELECT 1 FROM assignment_policies WHERE account_id = NEW.account_id AND id = NEW.source_record_id
        ) THEN
          RAISE EXCEPTION 'thread state fact source assignment policy must belong to account' USING ERRCODE = 'foreign_key_violation';
        ELSIF NEW.source_record_type = 'AutomationRule' AND NOT EXISTS (
          SELECT 1 FROM automation_rules WHERE account_id = NEW.account_id AND id = NEW.source_record_id
        ) THEN
          RAISE EXCEPTION 'thread state fact source automation rule must belong to account' USING ERRCODE = 'foreign_key_violation';
        ELSIF NEW.source_record_type = 'Inbox' AND NOT EXISTS (
          SELECT 1 FROM inboxes WHERE account_id = NEW.account_id AND id = NEW.source_record_id
        ) THEN
          RAISE EXCEPTION 'thread state fact source inbox must belong to account' USING ERRCODE = 'foreign_key_violation';
        ELSIF NEW.source_record_type = 'AccountUser' AND NOT EXISTS (
          SELECT 1 FROM account_users WHERE account_id = NEW.account_id AND id = NEW.source_record_id
        ) THEN
          RAISE EXCEPTION 'thread state fact source account user must belong to account' USING ERRCODE = 'foreign_key_violation';
        ELSIF NEW.source_record_type IS NOT NULL AND NEW.source_record_type NOT IN (
          'Contact', 'Conversation', 'CommunicationThread', 'Team', 'AssignmentPolicy', 'AutomationRule', 'Inbox', 'AccountUser'
        ) THEN
          RAISE EXCEPTION 'thread state fact source record type is unsupported' USING ERRCODE = 'check_violation';
        END IF;

        IF NEW.actor_kind = 'user' AND NOT EXISTS (
          SELECT 1 FROM account_users WHERE account_id = NEW.account_id AND user_id = NEW.actor_id
        ) THEN
          RAISE EXCEPTION 'thread state fact actor must belong to account' USING ERRCODE = 'foreign_key_violation';
        ELSIF NEW.actor_kind = 'contact' AND NOT EXISTS (
          SELECT 1 FROM contacts WHERE account_id = NEW.account_id AND id = NEW.actor_id
        ) THEN
          RAISE EXCEPTION 'thread state fact contact actor must belong to account' USING ERRCODE = 'foreign_key_violation';
        ELSIF NEW.actor_kind = 'captain' AND NOT EXISTS (
          SELECT 1 FROM captain_assistants WHERE account_id = NEW.account_id AND id = NEW.actor_id
        ) THEN
          RAISE EXCEPTION 'thread state fact captain actor must belong to account' USING ERRCODE = 'foreign_key_violation';
        ELSIF NEW.actor_kind = 'automation' AND NOT (
          (NEW.source_record_type = 'AssignmentPolicy' AND EXISTS (
            SELECT 1 FROM assignment_policies WHERE account_id = NEW.account_id AND id = NEW.actor_id
          )) OR
          (NEW.source_record_type = 'AutomationRule' AND EXISTS (
            SELECT 1 FROM automation_rules WHERE account_id = NEW.account_id AND id = NEW.actor_id
          )) OR
          (NEW.source_record_type = 'Inbox' AND EXISTS (
            SELECT 1 FROM inboxes WHERE account_id = NEW.account_id AND id = NEW.actor_id
          ))
        ) THEN
          RAISE EXCEPTION 'thread state fact automation actor must belong to account' USING ERRCODE = 'foreign_key_violation';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER validate_thread_state_transition_fact_insert
      BEFORE INSERT ON communication_thread_state_transition_facts
      FOR EACH ROW
      EXECUTE FUNCTION validate_thread_state_transition_fact_insert();
    SQL
  end

  def create_projection_fallback_trigger # rubocop:disable Metrics/MethodLength
    execute <<~SQL.squish
      CREATE FUNCTION record_thread_state_transition_fallback()
      RETURNS trigger AS $$
      DECLARE
        operation_id uuid := gen_random_uuid();
        transition_time timestamp without time zone := clock_timestamp();
        requested_time timestamp without time zone := transition_time;
        transition_kind text;
        previous_status text;
        current_status text;
        previous_assignee_name text;
        current_assignee_name text;
        previous_team_name text;
        current_team_name text;
      BEGIN
        IF NULLIF(current_setting('onelink.thread_state_fact_writer', true), '') IS NOT NULL THEN
          RETURN NEW;
        END IF;

        IF TG_OP = 'UPDATE' AND
           OLD.assignee_id IS NOT DISTINCT FROM NEW.assignee_id AND
           OLD.team_id IS NOT DISTINCT FROM NEW.team_id AND
           OLD.status IS NOT DISTINCT FROM NEW.status THEN
          RETURN NEW;
        END IF;

        current_status := CASE NEW.status WHEN 0 THEN 'open' WHEN 1 THEN 'resolved' WHEN 2 THEN 'pending' WHEN 3 THEN 'snoozed' END;
        IF TG_OP = 'INSERT' THEN
          transition_kind := 'created';
        ELSE
          previous_status := CASE OLD.status WHEN 0 THEN 'open' WHEN 1 THEN 'resolved' WHEN 2 THEN 'pending' WHEN 3 THEN 'snoozed' END;
          transition_kind := CASE
            WHEN OLD.status <> 1 AND NEW.status = 1 THEN 'resolved'
            WHEN OLD.status = 1 AND NEW.status <> 1 THEN 'reopened'
            WHEN OLD.assignee_id IS DISTINCT FROM NEW.assignee_id OR OLD.team_id IS DISTINCT FROM NEW.team_id THEN 'routing_changed'
            ELSE 'state_changed'
          END;

          SELECT users.name INTO previous_assignee_name
          FROM users INNER JOIN account_users ON account_users.user_id = users.id
          WHERE account_users.account_id = NEW.account_id AND users.id = OLD.assignee_id;
          SELECT name INTO previous_team_name FROM teams WHERE account_id = NEW.account_id AND id = OLD.team_id;
        END IF;

        SELECT users.name INTO current_assignee_name
        FROM users INNER JOIN account_users ON account_users.user_id = users.id
        WHERE account_users.account_id = NEW.account_id AND users.id = NEW.assignee_id;
        SELECT name INTO current_team_name FROM teams WHERE account_id = NEW.account_id AND id = NEW.team_id;

        transition_time := GREATEST(transition_time, COALESCE((
          SELECT occurred_at + interval '1 microsecond' FROM communication_thread_state_transition_facts
          WHERE account_id = NEW.account_id AND communication_thread_id_snapshot = NEW.id
          ORDER BY occurred_at DESC, id DESC LIMIT 1
        ), transition_time));

        INSERT INTO communication_thread_state_transition_facts (
          account_id, communication_thread_id_snapshot, thread_display_id_snapshot, contact_id_snapshot,
          event_kind, occurred_at, requested_occurred_at, reliable_since, source_version,
          from_assignee_id, from_assignee_name, to_assignee_id, to_assignee_name,
          from_team_id, from_team_name, to_team_id, to_team_name, from_status, to_status,
          source, source_record_type, source_record_id, source_event_id,
          actor_kind, actor_id, actor_name, idempotency_key, created_at
        ) VALUES (
          NEW.account_id, NEW.id, NEW.display_id, NEW.contact_id,
          transition_kind, transition_time, requested_time, transition_time, 1,
          CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.assignee_id END,
          CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE previous_assignee_name END,
          NEW.assignee_id, current_assignee_name,
          CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.team_id END,
          CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE previous_team_name END,
          NEW.team_id, current_team_name,
          CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE previous_status END, current_status,
          'database_projection_fallback', 'CommunicationThread', NEW.id, operation_id,
          'system', NULL, 'System',
          CASE WHEN TG_OP = 'INSERT' THEN 'thread:' || NEW.id || ':created:v1'
               ELSE 'thread:' || NEW.id || ':state:' || operation_id || ':v1' END,
          transition_time
        ) ON CONFLICT (account_id, idempotency_key) DO NOTHING;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER record_thread_state_transition_fallback
      AFTER INSERT OR UPDATE ON communication_threads
      FOR EACH ROW
      EXECUTE FUNCTION record_thread_state_transition_fallback();
    SQL
  end

  def create_immutability_trigger
    execute <<~SQL.squish
      CREATE FUNCTION prevent_thread_state_transition_fact_changes()
      RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM accounts WHERE id = OLD.account_id) THEN
          RETURN OLD;
        END IF;

        RAISE EXCEPTION 'communication thread state transition facts are append-only' USING ERRCODE = 'check_violation';
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER prevent_thread_state_transition_fact_changes
      BEFORE UPDATE OR DELETE ON communication_thread_state_transition_facts
      FOR EACH ROW
      EXECUTE FUNCTION prevent_thread_state_transition_fact_changes();
    SQL
  end

  def quoted_values(values)
    values.map { |value| connection.quote(value) }.join(', ')
  end
end
