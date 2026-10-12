# frozen_string_literal: true

# Production runs this while the previous release still serves traffic, so it is
# a short-locked expand: NOT VALID keys and checks validated afterwards, a
# concurrent unique index and batched backfills (script/onelink/change_plan.py).
class AddCaptainChannelMembership < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  LOCK_TIMEOUT = '5s'.freeze
  LOCK_ATTEMPTS = 5
  BATCH_SIZE = 1_000
  UNIQUE_INBOX_INDEX = 'index_captain_inboxes_on_unique_inbox_id'.freeze
  SCOPE_CHECK = 'captain_assistants_channel_scope'.freeze

  def up
    add_flag_columns
    create_membership_table
    add_constraints
    backfill_membership!
    enable_existing_channels
    scope_existing_external_agents
    add_unique_inbox_index
    validate_constraints
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Captain channel membership preserves existing routing data'
  end

  # The recursive walk mirrors AgentGraph: entry plus active external targets,
  # including transitive edges. Conflict handling makes this safe to rerun.
  def backfill_membership!
    execute <<~SQL.squish
      WITH RECURSIVE reachable(inbox_id, account_id, assistant_id) AS (
        SELECT ci.inbox_id, a.account_id, a.id
        FROM captain_inboxes ci
        JOIN captain_assistants a ON a.id = ci.captain_assistant_id
        JOIN inboxes i ON i.id = ci.inbox_id AND i.account_id = a.account_id
        WHERE a.active = TRUE AND a.usage_mode = 'external_agent'
          AND i.channel_type IS DISTINCT FROM 'Channel::Voice'
        UNION
        SELECT r.inbox_id, r.account_id, target.id
        FROM reachable r
        JOIN captain_agent_handoffs h ON h.source_assistant_id = r.assistant_id AND h.account_id = r.account_id
        JOIN captain_assistants target ON target.id = h.target_assistant_id AND target.account_id = r.account_id
        WHERE target.active = TRUE AND target.usage_mode = 'external_agent'
      )
      INSERT INTO captain_agent_channels (account_id, assistant_id, inbox_id, created_at, updated_at)
      SELECT account_id, assistant_id, inbox_id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM reachable
      ON CONFLICT (assistant_id, inbox_id) DO NOTHING
    SQL
  end

  private

  def add_flag_columns
    with_short_lock_timeout do
      add_column :captain_assistants, :channel_scope, :string, null: false, default: 'all' unless column_exists?(:captain_assistants, :channel_scope)
    end
    with_short_lock_timeout do
      add_column :captain_inboxes, :ai_enabled, :boolean, null: false, default: false unless column_exists?(:captain_inboxes, :ai_enabled)
    end
  end

  def create_membership_table
    return if table_exists?(:captain_agent_channels)

    with_short_lock_timeout do
      create_table :captain_agent_channels do |t|
        t.bigint :account_id, null: false
        t.bigint :assistant_id, null: false
        t.bigint :inbox_id, null: false
        t.timestamps
      end
      add_index :captain_agent_channels, [:assistant_id, :inbox_id], unique: true
      add_index :captain_agent_channels, :inbox_id
      add_index :captain_agent_channels, :account_id
    end
  end

  def add_constraints
    with_short_lock_timeout { add_foreign_key :captain_agent_channels, :accounts, validate: false, if_not_exists: true }
    with_short_lock_timeout do
      add_foreign_key :captain_agent_channels, :captain_assistants, column: [:assistant_id, :account_id],
                                                                   primary_key: [:id, :account_id], on_delete: :cascade,
                                                                   validate: false, if_not_exists: true
    end
    with_short_lock_timeout do
      add_foreign_key :captain_agent_channels, :inboxes, column: :inbox_id, on_delete: :cascade, validate: false, if_not_exists: true
    end
    return if check_constraint_exists?(:captain_assistants, name: SCOPE_CHECK)

    with_short_lock_timeout do
      add_check_constraint :captain_assistants, "channel_scope IN ('all', 'selected')", name: SCOPE_CHECK, validate: false
    end
  end

  # Existing AI links keep answering: the previous release had no per-channel switch.
  def enable_existing_channels
    batch_update(<<~SQL.squish)
      UPDATE captain_inboxes SET ai_enabled = TRUE
      WHERE id IN (SELECT id FROM captain_inboxes WHERE ai_enabled = FALSE ORDER BY id LIMIT #{BATCH_SIZE})
    SQL
  end

  # External agents keep exactly the channels they could reach before (backfilled above).
  def scope_existing_external_agents
    batch_update(<<~SQL.squish)
      UPDATE captain_assistants SET channel_scope = 'selected'
      WHERE id IN (
        SELECT id FROM captain_assistants
        WHERE usage_mode = 'external_agent' AND channel_scope <> 'selected' ORDER BY id LIMIT #{BATCH_SIZE}
      )
    SQL
  end

  def batch_update(sql)
    loop do
      updated = with_short_lock_timeout { exec_update(sql) }
      break if updated.to_i < BATCH_SIZE
    end
  end

  def add_unique_inbox_index
    duplicate_ids = select_values('SELECT inbox_id FROM captain_inboxes GROUP BY inbox_id HAVING COUNT(*) > 1 ORDER BY inbox_id')
    return say("Captain inbox duplicate inbox ids: #{duplicate_ids.join(', ')}") if duplicate_ids.any?

    invalid = select_value("SELECT 1 FROM pg_index WHERE indexrelid = to_regclass(#{quote(UNIQUE_INBOX_INDEX)}) AND NOT indisvalid")
    execute("REINDEX INDEX CONCURRENTLY #{quote_table_name(UNIQUE_INBOX_INDEX)}") if invalid.present?
    add_index :captain_inboxes, :inbox_id, unique: true, name: UNIQUE_INBOX_INDEX, algorithm: :concurrently, if_not_exists: true
  end

  def validate_constraints
    connection.foreign_keys(:captain_agent_channels).each do |constraint|
      validate_foreign_key :captain_agent_channels, name: constraint.name unless constraint.validated?
    end
    constraint = connection.check_constraints(:captain_assistants).find { |check| check.name == SCOPE_CHECK }
    validate_check_constraint :captain_assistants, name: SCOPE_CHECK if constraint && !constraint.validate?
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
end
