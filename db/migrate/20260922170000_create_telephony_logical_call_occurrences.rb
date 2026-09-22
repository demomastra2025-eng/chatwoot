class CreateTelephonyLogicalCallOccurrences < ActiveRecord::Migration[7.1] # rubocop:disable Metrics/ClassLength
  OCCURRENCE_KINDS = %w[attempted connected terminal].freeze
  DIRECTIONS = %w[inbound outbound].freeze
  ACTOR_KINDS = %w[human ai_agent system unknown].freeze
  RELIABILITIES = %w[exact unknown].freeze
  SOURCE_KINDS = %w[telephony_call_session].freeze
  DURATION_SOURCES = %w[connected_to_terminal provider_reported].freeze

  def up
    create_occurrences_table
    add_indexes
    add_checks
    create_insert_contract_trigger
    create_immutability_trigger
  end

  def down
    execute 'DROP TRIGGER IF EXISTS validate_telephony_logical_call_occurrence_insert ON telephony_logical_call_occurrences'
    execute 'DROP FUNCTION IF EXISTS validate_telephony_logical_call_occurrence_insert()'
    execute 'DROP TRIGGER IF EXISTS prevent_telephony_logical_call_occurrence_changes ON telephony_logical_call_occurrences'
    execute 'DROP FUNCTION IF EXISTS prevent_telephony_logical_call_occurrence_changes()'
    drop_table :telephony_logical_call_occurrences
  end

  private

  def create_occurrences_table # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    create_table :telephony_logical_call_occurrences do |t| # rubocop:disable Metrics/BlockLength
      t.references :account, null: false, foreign_key: true
      t.string :logical_call_identity, null: false
      t.string :logical_call_ref, null: false
      t.string :occurrence_kind, null: false
      t.string :source_kind, null: false
      t.bigint :source_id, null: false
      t.string :source_ref, null: false
      t.string :correlation_ref
      t.string :provider, null: false
      t.string :direction, null: false
      t.bigint :inbox_id_snapshot
      t.bigint :contact_id_snapshot
      t.bigint :conversation_id_snapshot
      t.bigint :communication_thread_id_snapshot
      t.string :actor_kind, null: false, default: 'unknown'
      t.bigint :actor_id_snapshot
      t.string :actor_name_snapshot
      t.bigint :actor_team_id_snapshot
      t.string :actor_team_name_snapshot
      t.bigint :assistant_id_snapshot
      t.string :assistant_name_snapshot
      t.datetime :occurred_at, null: false
      t.datetime :connected_at
      t.datetime :terminal_at
      t.integer :duration_seconds
      t.string :duration_source
      t.string :terminal_status
      t.string :terminal_reason
      t.string :reliability, null: false, default: 'exact'
      t.datetime :reliable_since, null: false
      t.integer :source_version, null: false, default: 1
      t.integer :definition_version, null: false, default: 1
      t.integer :revision, null: false, default: 1
      t.bigint :supersedes_occurrence_id
      t.datetime :created_at, null: false
    end
  end

  def add_indexes
    add_index :telephony_logical_call_occurrences,
              [:account_id, :logical_call_identity, :occurrence_kind, :source_version, :revision],
              unique: true,
              name: 'idx_telephony_occurrences_logical_grain'
    add_index :telephony_logical_call_occurrences,
              :supersedes_occurrence_id,
              unique: true,
              where: 'supersedes_occurrence_id IS NOT NULL',
              name: 'idx_telephony_occurrences_one_successor'
    add_index :telephony_logical_call_occurrences,
              [:account_id, :occurrence_kind, :occurred_at, :id],
              name: 'idx_telephony_occurrences_account_kind_time'
    add_index :telephony_logical_call_occurrences,
              [:account_id, :logical_call_identity, :occurred_at, :id],
              name: 'idx_telephony_occurrences_logical_time'
    add_index :telephony_logical_call_occurrences,
              [:account_id, :actor_kind, :actor_id_snapshot, :occurred_at, :id],
              name: 'idx_telephony_occurrences_actor_time'
  end

  def add_checks # rubocop:disable Metrics/MethodLength
    add_check_constraint :telephony_logical_call_occurrences,
                         "occurrence_kind IN (#{quoted_values(OCCURRENCE_KINDS)})",
                         name: 'chk_telephony_occurrences_kind'
    add_check_constraint :telephony_logical_call_occurrences,
                         "direction IN (#{quoted_values(DIRECTIONS)})",
                         name: 'chk_telephony_occurrences_direction'
    add_check_constraint :telephony_logical_call_occurrences,
                         "actor_kind IN (#{quoted_values(ACTOR_KINDS)})",
                         name: 'chk_telephony_occurrences_actor_kind'
    add_check_constraint :telephony_logical_call_occurrences,
                         "reliability IN (#{quoted_values(RELIABILITIES)})",
                         name: 'chk_telephony_occurrences_reliability'
    add_check_constraint :telephony_logical_call_occurrences,
                         "source_kind IN (#{quoted_values(SOURCE_KINDS)})",
                         name: 'chk_telephony_occurrences_source_kind'
    add_check_constraint :telephony_logical_call_occurrences,
                         "duration_source IS NULL OR duration_source IN (#{quoted_values(DURATION_SOURCES)})",
                         name: 'chk_telephony_occurrences_duration_source'
    add_check_constraint :telephony_logical_call_occurrences,
                         'source_version = 1 AND definition_version = 1',
                         name: 'chk_telephony_occurrences_versions'
    add_check_constraint :telephony_logical_call_occurrences,
                         'revision >= 1',
                         name: 'chk_telephony_occurrences_revision'
    add_check_constraint :telephony_logical_call_occurrences,
                         '(revision = 1 AND supersedes_occurrence_id IS NULL) OR ' \
                         '(revision > 1 AND supersedes_occurrence_id IS NOT NULL)',
                         name: 'chk_telephony_occurrences_supersession'
    add_check_constraint :telephony_logical_call_occurrences,
                         'duration_seconds IS NULL OR duration_seconds >= 0',
                         name: 'chk_telephony_occurrences_duration'
    add_check_constraint :telephony_logical_call_occurrences,
                         "(occurrence_kind = 'attempted' AND connected_at IS NULL AND terminal_at IS NULL) OR " \
                         "(occurrence_kind = 'connected' AND (connected_at IS NOT NULL OR reliability = 'unknown') AND terminal_at IS NULL) OR " \
                         "(occurrence_kind = 'terminal' AND terminal_at IS NOT NULL)",
                         name: 'chk_telephony_occurrences_timestamps'
    add_check_constraint :telephony_logical_call_occurrences,
                         "occurrence_kind = 'terminal' OR (duration_seconds IS NULL AND duration_source IS NULL AND terminal_status IS NULL)",
                         name: 'chk_telephony_occurrences_terminal_fields'
    add_check_constraint :telephony_logical_call_occurrences,
                         "actor_kind = 'human' OR (actor_id_snapshot IS NULL AND actor_team_id_snapshot IS NULL)",
                         name: 'chk_telephony_occurrences_human_actor'
    add_check_constraint :telephony_logical_call_occurrences,
                         "actor_kind = 'ai_agent' OR (assistant_id_snapshot IS NULL AND assistant_name_snapshot IS NULL)",
                         name: 'chk_telephony_occurrences_ai_actor'
  end

  def create_insert_contract_trigger # rubocop:disable Metrics/MethodLength
    execute <<~SQL.squish
      CREATE FUNCTION validate_telephony_logical_call_occurrence_insert()
      RETURNS trigger AS $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM telephony_call_sessions
          WHERE id = NEW.source_id
            AND account_id = NEW.account_id
            AND external_call_ref = NEW.source_ref
            AND provider = NEW.provider
            AND direction = NEW.direction
        ) THEN
          RAISE EXCEPTION 'telephony occurrence source must belong to account and match its immutable source snapshot'
            USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF NEW.inbox_id_snapshot IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM inboxes WHERE id = NEW.inbox_id_snapshot AND account_id = NEW.account_id
        ) THEN
          RAISE EXCEPTION 'telephony occurrence inbox snapshot must belong to account' USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF NEW.contact_id_snapshot IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM contacts WHERE id = NEW.contact_id_snapshot AND account_id = NEW.account_id
        ) THEN
          RAISE EXCEPTION 'telephony occurrence contact snapshot must belong to account' USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF NEW.conversation_id_snapshot IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM conversations WHERE id = NEW.conversation_id_snapshot AND account_id = NEW.account_id
        ) THEN
          RAISE EXCEPTION 'telephony occurrence conversation snapshot must belong to account' USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF NEW.communication_thread_id_snapshot IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM communication_threads WHERE id = NEW.communication_thread_id_snapshot AND account_id = NEW.account_id
        ) THEN
          RAISE EXCEPTION 'telephony occurrence thread snapshot must belong to account' USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF NEW.actor_id_snapshot IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM account_users WHERE account_id = NEW.account_id AND user_id = NEW.actor_id_snapshot
        ) AND NOT (
          NEW.occurrence_kind = 'terminal' AND EXISTS (
            SELECT 1 FROM telephony_logical_call_occurrences
            WHERE account_id = NEW.account_id
              AND logical_call_identity = NEW.logical_call_identity
              AND occurrence_kind = 'connected'
              AND actor_id_snapshot = NEW.actor_id_snapshot
          )
        ) THEN
          RAISE EXCEPTION 'telephony occurrence actor snapshot must belong to account' USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF NEW.actor_team_id_snapshot IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM teams WHERE id = NEW.actor_team_id_snapshot AND account_id = NEW.account_id
        ) AND NOT (
          NEW.occurrence_kind = 'terminal' AND EXISTS (
            SELECT 1 FROM telephony_logical_call_occurrences
            WHERE account_id = NEW.account_id
              AND logical_call_identity = NEW.logical_call_identity
              AND occurrence_kind = 'connected'
              AND actor_team_id_snapshot = NEW.actor_team_id_snapshot
          )
        ) THEN
          RAISE EXCEPTION 'telephony occurrence team snapshot must belong to account' USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF NEW.assistant_id_snapshot IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM captain_assistants WHERE id = NEW.assistant_id_snapshot AND account_id = NEW.account_id
        ) AND NOT (
          NEW.occurrence_kind = 'terminal' AND EXISTS (
            SELECT 1 FROM telephony_logical_call_occurrences
            WHERE account_id = NEW.account_id
              AND logical_call_identity = NEW.logical_call_identity
              AND occurrence_kind = 'connected'
              AND assistant_id_snapshot = NEW.assistant_id_snapshot
          )
        ) THEN
          RAISE EXCEPTION 'telephony occurrence assistant snapshot must belong to account' USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF NEW.supersedes_occurrence_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM telephony_logical_call_occurrences
          WHERE id = NEW.supersedes_occurrence_id
            AND account_id = NEW.account_id
            AND logical_call_identity = NEW.logical_call_identity
            AND occurrence_kind = NEW.occurrence_kind
            AND source_version = NEW.source_version
            AND revision = NEW.revision - 1
        ) THEN
          RAISE EXCEPTION 'telephony occurrence supersession must extend the same logical fact by one revision'
            USING ERRCODE = 'foreign_key_violation';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER validate_telephony_logical_call_occurrence_insert
      BEFORE INSERT ON telephony_logical_call_occurrences
      FOR EACH ROW
      EXECUTE FUNCTION validate_telephony_logical_call_occurrence_insert();
    SQL
  end

  def create_immutability_trigger
    execute <<~SQL.squish
      CREATE FUNCTION prevent_telephony_logical_call_occurrence_changes()
      RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' AND
           current_setting('onelink.account_teardown_id', true) = OLD.account_id::text THEN
          RETURN OLD;
        END IF;

        RAISE EXCEPTION 'telephony logical call occurrences are append-only' USING ERRCODE = 'check_violation';
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER prevent_telephony_logical_call_occurrence_changes
      BEFORE UPDATE OR DELETE ON telephony_logical_call_occurrences
      FOR EACH ROW
      EXECUTE FUNCTION prevent_telephony_logical_call_occurrence_changes();
    SQL
  end

  def quoted_values(values)
    values.map { |value| connection.quote(value) }.join(', ')
  end
end
