class CreateAutomationActionReceipts < ActiveRecord::Migration[7.1]
  STATUSES = %w[pending processing retrying succeeded skipped needs_attention].freeze
  IMMUTABLE_COLUMNS = %w[account_id automation_execution_id action_id position action_signature created_at].freeze
  IMMUTABILITY_TRIGGER_SQL = <<~SQL.squish.freeze
    CREATE FUNCTION prevent_automation_action_receipt_identity_changes()
    RETURNS trigger AS $$
    BEGIN
      IF %<columns>s THEN
        RAISE EXCEPTION 'automation action receipt identity is immutable' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;

    CREATE TRIGGER prevent_automation_action_receipt_identity_changes
    BEFORE UPDATE ON automation_action_receipts
    FOR EACH ROW
    EXECUTE FUNCTION prevent_automation_action_receipt_identity_changes();
  SQL
  IDENTITY_FUNCTION_SQL = <<~SQL.squish.freeze
    CREATE FUNCTION automation_action_signature(action_snapshot jsonb)
    RETURNS text AS $$
      SELECT encode(digest(convert_to(action_snapshot::text, 'UTF8'), 'sha256'), 'hex');
    $$ LANGUAGE SQL IMMUTABLE STRICT;
  SQL
  INSERT_IDENTITY_TRIGGER_SQL = <<~SQL.squish.freeze
    CREATE FUNCTION derive_automation_action_receipt_identity()
    RETURNS trigger AS $$
    DECLARE
      action_snapshot jsonb;
      expected_action_id text;
      expected_signature text;
    BEGIN
      SELECT actions_snapshot -> NEW.position
      INTO action_snapshot
      FROM automation_executions
      WHERE account_id = NEW.account_id AND id = NEW.automation_execution_id;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'automation action receipt execution does not exist in account' USING ERRCODE = 'foreign_key_violation';
      END IF;
      IF action_snapshot IS NULL THEN
        RAISE EXCEPTION 'automation action receipt position is absent from execution snapshot' USING ERRCODE = 'check_violation';
      END IF;

      expected_action_id := COALESCE(NULLIF(btrim(action_snapshot ->> 'action_id'), ''), 'legacy-index:' || NEW.position);
      expected_signature := automation_action_signature(action_snapshot);

      IF NEW.action_id IS NOT NULL AND NEW.action_id IS DISTINCT FROM expected_action_id THEN
        RAISE EXCEPTION 'automation action receipt id does not match execution snapshot' USING ERRCODE = 'check_violation';
      END IF;
      IF NEW.action_signature IS NOT NULL AND NEW.action_signature IS DISTINCT FROM expected_signature THEN
        RAISE EXCEPTION 'automation action receipt signature does not match execution snapshot' USING ERRCODE = 'check_violation';
      END IF;

      NEW.action_id := expected_action_id;
      NEW.action_signature := expected_signature;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;

    CREATE TRIGGER derive_automation_action_receipt_identity
    BEFORE INSERT ON automation_action_receipts
    FOR EACH ROW
    EXECUTE FUNCTION derive_automation_action_receipt_identity();
  SQL

  def up
    create_automation_action_receipts
    add_indexes
    add_constraints
    add_account_consistent_foreign_key
    create_identity_contract
    create_immutability_trigger
  end

  def down
    execute 'DROP TRIGGER IF EXISTS derive_automation_action_receipt_identity ON automation_action_receipts'
    execute 'DROP FUNCTION IF EXISTS derive_automation_action_receipt_identity()'
    execute 'DROP FUNCTION IF EXISTS automation_action_signature(jsonb)'
    execute 'DROP TRIGGER IF EXISTS prevent_automation_action_receipt_identity_changes ON automation_action_receipts'
    execute 'DROP FUNCTION IF EXISTS prevent_automation_action_receipt_identity_changes()'
    drop_table :automation_action_receipts
  end

  private

  def create_automation_action_receipts
    create_table :automation_action_receipts do |t|
      t.references :account, null: false, foreign_key: true
      t.references :automation_execution, null: false, foreign_key: true
      t.string :action_id, null: false
      t.integer :position, null: false
      t.string :action_signature, null: false
      t.string :effect_key
      t.string :status, null: false, default: 'pending'
      t.integer :attempts, null: false, default: 0
      t.string :lease_owner
      t.datetime :lease_expires_at
      t.datetime :next_attempt_at, null: false, default: -> { 'CURRENT_TIMESTAMP' }
      t.jsonb :result, null: false, default: {}
      t.text :last_error
      t.datetime :completed_at
      t.datetime :needs_attention_at
      t.timestamps
    end
  end

  def add_indexes # rubocop:disable Metrics/MethodLength
    add_index :automation_action_receipts,
              [:automation_execution_id, :action_id],
              unique: true,
              name: 'idx_automation_action_receipts_on_execution_action'
    add_index :automation_action_receipts,
              [:automation_execution_id, :position],
              unique: true,
              name: 'idx_automation_action_receipts_on_execution_position'
    add_index :automation_action_receipts,
              [:next_attempt_at, :id],
              where: "status IN ('pending', 'retrying')",
              name: 'idx_automation_action_receipts_ready'
    add_index :automation_action_receipts,
              [:lease_expires_at, :id],
              where: "status = 'processing'",
              name: 'idx_automation_action_receipts_expired_lease'
    add_index :automation_action_receipts,
              [:account_id, :effect_key],
              unique: true,
              where: 'effect_key IS NOT NULL',
              name: 'idx_automation_action_receipts_on_account_effect'
  end

  def add_constraints
    add_check_constraint :automation_action_receipts,
                         "status IN (#{quoted_list(STATUSES)})",
                         name: 'automation_action_receipts_supported_status'
    add_check_constraint :automation_action_receipts, 'position >= 0', name: 'automation_action_receipts_non_negative_position'
    add_check_constraint :automation_action_receipts, 'attempts >= 0', name: 'automation_action_receipts_non_negative_attempts'
    add_check_constraint :automation_action_receipts, "btrim(action_id) <> ''", name: 'automation_action_receipts_non_blank_action_id'
    add_check_constraint :automation_action_receipts, "btrim(action_signature) <> ''", name: 'automation_action_receipts_non_blank_signature'
    add_check_constraint :automation_action_receipts,
                         "jsonb_typeof(result) = 'object'",
                         name: 'automation_action_receipts_object_result'
    add_check_constraint :automation_action_receipts,
                         "(status = 'processing' AND lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL) OR " \
                         "(status <> 'processing' AND lease_owner IS NULL AND lease_expires_at IS NULL)",
                         name: 'automation_action_receipts_status_lease_coherence'
    add_check_constraint :automation_action_receipts,
                         "(status = 'needs_attention' AND needs_attention_at IS NOT NULL) OR " \
                         "(status <> 'needs_attention' AND needs_attention_at IS NULL)",
                         name: 'automation_action_receipts_attention_state'
  end

  def add_account_consistent_foreign_key
    add_foreign_key :automation_action_receipts,
                    :automation_executions,
                    column: [:account_id, :automation_execution_id],
                    primary_key: [:account_id, :id],
                    name: 'fk_automation_action_receipts_execution_account'
  end

  def quoted_list(values)
    values.map { |value| connection.quote(value) }.join(', ')
  end

  def create_immutability_trigger
    columns = IMMUTABLE_COLUMNS.map { |column| "NEW.#{column} IS DISTINCT FROM OLD.#{column}" }.join(' OR ')
    execute format(IMMUTABILITY_TRIGGER_SQL, columns: columns)
  end

  def create_identity_contract
    execute IDENTITY_FUNCTION_SQL
    execute INSERT_IDENTITY_TRIGGER_SQL
  end
end
