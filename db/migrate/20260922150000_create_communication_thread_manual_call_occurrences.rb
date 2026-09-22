class CreateCommunicationThreadManualCallOccurrences < ActiveRecord::Migration[7.1]
  SOURCE_KINDS = %w[telephony_call_session].freeze

  def up
    create_occurrences_table
    add_indexes
    add_checks
    create_insert_contract_trigger
    create_immutability_trigger
  end

  def down
    execute 'DROP TRIGGER IF EXISTS validate_thread_manual_call_occurrence_insert ON communication_thread_manual_call_occurrences'
    execute 'DROP FUNCTION IF EXISTS validate_thread_manual_call_occurrence_insert()'
    execute 'DROP TRIGGER IF EXISTS prevent_thread_manual_call_occurrence_changes ON communication_thread_manual_call_occurrences'
    execute 'DROP FUNCTION IF EXISTS prevent_thread_manual_call_occurrence_changes()'
    drop_table :communication_thread_manual_call_occurrences
  end

  private

  def create_occurrences_table
    create_table :communication_thread_manual_call_occurrences do |t|
      t.references :account, null: false, foreign_key: true
      t.bigint :communication_thread_id, null: false
      t.string :actor_type, null: false, default: 'User'
      t.bigint :actor_id, null: false
      t.string :actor_name, null: false
      t.string :source_kind, null: false
      t.bigint :source_id, null: false
      t.string :source_ref, null: false
      t.datetime :occurred_at, null: false
      t.datetime :reliable_since, null: false
      t.integer :schema_version, null: false, default: 1
      t.datetime :created_at, null: false
    end
  end

  def add_indexes
    add_index :communication_thread_manual_call_occurrences,
              [:account_id, :source_kind, :source_id],
              unique: true,
              name: 'idx_thread_manual_calls_source_identity'
    add_index :communication_thread_manual_call_occurrences,
              [:account_id, :communication_thread_id, :occurred_at, :id],
              name: 'idx_thread_manual_calls_thread_time'
    add_index :communication_thread_manual_call_occurrences,
              [:account_id, :actor_id, :occurred_at, :id],
              name: 'idx_thread_manual_calls_actor_time'
  end

  def add_checks
    add_check_constraint :communication_thread_manual_call_occurrences,
                         "source_kind IN (#{quoted_values(SOURCE_KINDS)})",
                         name: 'chk_thread_manual_calls_source_kind'
    add_check_constraint :communication_thread_manual_call_occurrences,
                         "actor_type = 'User'",
                         name: 'chk_thread_manual_calls_actor_type'
    add_check_constraint :communication_thread_manual_call_occurrences,
                         'schema_version = 1',
                         name: 'chk_thread_manual_calls_schema_version'
    add_check_constraint :communication_thread_manual_call_occurrences,
                         'reliable_since <= occurred_at',
                         name: 'chk_thread_manual_calls_reliable_since'
  end

  def create_insert_contract_trigger # rubocop:disable Metrics/MethodLength
    execute <<~SQL.squish
      CREATE FUNCTION validate_thread_manual_call_occurrence_insert()
      RETURNS trigger AS $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM communication_threads
          WHERE id = NEW.communication_thread_id AND account_id = NEW.account_id
        ) THEN
          RAISE EXCEPTION 'manual call occurrence thread must belong to account' USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM account_users
          WHERE account_id = NEW.account_id AND user_id = NEW.actor_id
        ) THEN
          RAISE EXCEPTION 'manual call occurrence actor must belong to account' USING ERRCODE = 'foreign_key_violation';
        END IF;

        IF NEW.source_kind = 'telephony_call_session' AND NOT EXISTS (
          SELECT 1 FROM telephony_call_sessions
          WHERE id = NEW.source_id
            AND account_id = NEW.account_id
            AND external_call_ref = NEW.source_ref
            AND direction = 'outbound'
            AND metadata -> 'metadata' ->> 'source' = 'onelink_browser_janus_sip'
            AND metadata -> 'metadata' ->> 'route_action' = 'operator'
            AND metadata -> 'metadata' ->> 'chatwoot_user_id' = NEW.actor_id::text
            AND NOT (metadata ? 'ai_voice')
            AND NOT (metadata -> 'metadata' ? 'ai_voice')
        ) THEN
          RAISE EXCEPTION 'manual call occurrence source must be an outbound call session in the same account'
            USING ERRCODE = 'foreign_key_violation';
        END IF;

        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER validate_thread_manual_call_occurrence_insert
      BEFORE INSERT ON communication_thread_manual_call_occurrences
      FOR EACH ROW
      EXECUTE FUNCTION validate_thread_manual_call_occurrence_insert();
    SQL
  end

  def create_immutability_trigger
    execute <<~SQL.squish
      CREATE FUNCTION prevent_thread_manual_call_occurrence_changes()
      RETURNS trigger AS $$
      BEGIN
        IF TG_OP = 'DELETE' AND
           current_setting('onelink.account_teardown_id', true) = OLD.account_id::text THEN
          RETURN OLD;
        END IF;

        RAISE EXCEPTION 'communication thread manual call occurrences are append-only' USING ERRCODE = 'check_violation';
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER prevent_thread_manual_call_occurrence_changes
      BEFORE UPDATE OR DELETE ON communication_thread_manual_call_occurrences
      FOR EACH ROW
      EXECUTE FUNCTION prevent_thread_manual_call_occurrence_changes();
    SQL
  end

  def quoted_values(values)
    values.map { |value| connection.quote(value) }.join(', ')
  end
end
