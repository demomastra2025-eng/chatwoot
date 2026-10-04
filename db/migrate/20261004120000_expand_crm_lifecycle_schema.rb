class ExpandCrmLifecycleSchema < ActiveRecord::Migration[7.1]
  DEFAULT_TIMEZONE = 'Asia/Almaty'.freeze
  DEADLINE_SHAPE = <<~SQL.squish.freeze
    (
      (all_day = TRUE AND due_on IS NOT NULL AND due_at IS NULL AND start_at IS NULL) OR
      (all_day = FALSE AND due_on IS NULL)
    )
  SQL

  def up
    expand_task_deadlines
    expand_task_lifecycle
    expand_task_catalogs
    expand_deal_waiting
    expand_stage_entry_rules
    expand_event_envelopes
    create_stage_visits
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'CRM lifecycle schema is additive; roll back application behavior without removing retained CRM data'
  end

  private

  def expand_task_deadlines
    add_column_if_missing(:crm_tasks, :all_day, :boolean, default: false, null: false)
    add_column_if_missing(:crm_tasks, :due_on, :date)
    add_column_if_missing(:crm_tasks, :schedule_timezone, :string, default: DEFAULT_TIMEZONE, null: false)
    backfill_account_timezones
    add_check_constraint_if_missing(:crm_tasks, DEADLINE_SHAPE, 'crm_tasks_deadline_shape')
    add_index_if_missing(:crm_tasks, %i[account_id due_on],
                         where: 'archived_at IS NULL',
                         name: 'index_crm_tasks_on_active_due_on')
  end

  # Existing CRM tasks have timed deadlines. Keep those timestamps intact; new
  # date-only tasks use due_on and never rewrite historical due_at/start_at.
  def backfill_account_timezones
    accounts_with_tasks = select_all(<<~SQL.squish)
      SELECT accounts.id, accounts.settings ->> 'reporting_timezone' AS reporting_timezone
      FROM accounts
      WHERE EXISTS (SELECT 1 FROM crm_tasks WHERE crm_tasks.account_id = accounts.id)
    SQL

    accounts_with_tasks.each do |row|
      zone = ActiveSupport::TimeZone[row['reporting_timezone']]
      timezone = zone&.tzinfo&.identifier.presence || DEFAULT_TIMEZONE
      execute <<~SQL.squish
        UPDATE crm_tasks
        SET schedule_timezone = #{connection.quote(timezone)}
        WHERE account_id = #{connection.quote(row['id'])}
      SQL
    end
  end

  def expand_task_lifecycle
    add_reference_if_missing(:crm_tasks, :completed_by, foreign_key: { to_table: :users, on_delete: :nullify })
    add_column_if_missing(:crm_tasks, :cancelled_at, :datetime)
    add_reference_if_missing(:crm_tasks, :cancelled_by, foreign_key: { to_table: :users, on_delete: :nullify })
    add_column_if_missing(:crm_tasks, :cancellation_reason, :text)
    add_column_if_missing(:crm_tasks, :reschedule_count, :integer, default: 0, null: false)
    add_column_if_missing(:crm_tasks, :context_kind, :string)

    execute <<~SQL.squish
      UPDATE crm_tasks
      SET context_kind = CASE WHEN deal_id IS NULL THEN 'personal' ELSE 'sales' END
      WHERE context_kind IS NULL
    SQL

    add_check_constraint_if_missing(
      :crm_tasks,
      'reschedule_count >= 0',
      'crm_tasks_reschedule_count_non_negative'
    )
    add_check_constraint_if_missing(
      :crm_tasks,
      <<~SQL.squish,
        (cancelled_at IS NULL AND cancellation_reason IS NULL) OR
        (cancelled_at IS NOT NULL AND LENGTH(BTRIM(cancellation_reason)) > 0)
      SQL
      'crm_tasks_cancellation_state_complete'
    )
  end

  def expand_task_catalogs
    create_task_types unless table_exists?(:crm_task_types)
    create_task_outcomes unless table_exists?(:crm_task_outcomes)
    add_reference_if_missing(:crm_tasks, :task_type, foreign_key: { to_table: :crm_task_types })
    add_reference_if_missing(:crm_tasks, :task_outcome, foreign_key: { to_table: :crm_task_outcomes })
    seed_task_catalogs
    add_index_if_missing(:crm_tasks, %i[account_id task_type_id due_at],
                         name: 'index_crm_tasks_on_account_type_due_at')
  end

  def create_task_types
    create_table :crm_task_types do |t|
      t.references :account, null: false, foreign_key: true
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

  def create_task_outcomes
    create_table :crm_task_outcomes do |t|
      t.references :account, null: false, foreign_key: true
      t.references :task_type, null: false, foreign_key: { to_table: :crm_task_types }
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

  def seed_task_catalogs
    types = [
      ['task', 'Task', 'i-lucide-list-todo', 1, true],
      ['call', 'Call', 'i-lucide-phone', 2, false],
      ['meeting', 'Meeting', 'i-lucide-users', 3, false],
      ['message', 'Message', 'i-lucide-message-square', 4, false],
      ['touch', 'Touch', 'i-lucide-handshake', 5, false]
    ]
    outcomes = {
      'task' => %w[completed not_done cancelled],
      'call' => %w[answered no_answer busy cancelled not_done],
      'meeting' => %w[held cancelled no_show rescheduled not_done],
      'message' => %w[sent failed not_done],
      'touch' => %w[completed no_answer cancelled not_done]
    }

    types.each do |code, name, icon, position, default|
      execute <<~SQL.squish
        INSERT INTO crm_task_types
          (account_id, name, code, icon, position, active, "default", created_at, updated_at)
        SELECT DISTINCT crm_tasks.account_id, #{connection.quote(name)}, #{connection.quote(code)},
          #{connection.quote(icon)}, #{position}, TRUE, #{connection.quote(default)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM crm_tasks
        WHERE NOT EXISTS (
          SELECT 1 FROM crm_task_types
          WHERE crm_task_types.account_id = crm_tasks.account_id AND crm_task_types.code = #{connection.quote(code)}
        )
      SQL
    end

    outcomes.each do |type_code, codes|
      codes.each_with_index do |code, index|
        execute <<~SQL.squish
          INSERT INTO crm_task_outcomes
            (account_id, task_type_id, name, code, position, active, "default", requires_note, created_at, updated_at)
          SELECT crm_task_types.account_id, crm_task_types.id, #{connection.quote(code.humanize)},
            #{connection.quote(code)}, #{index + 1}, TRUE, #{connection.quote(index.zero?)},
            #{connection.quote(code == 'not_done')}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
          FROM crm_task_types
          WHERE crm_task_types.code = #{connection.quote(type_code)}
            AND NOT EXISTS (
              SELECT 1 FROM crm_task_outcomes
              WHERE crm_task_outcomes.task_type_id = crm_task_types.id
                AND crm_task_outcomes.code = #{connection.quote(code)}
            )
        SQL
      end
    end

    execute <<~SQL.squish
      UPDATE crm_tasks
      SET task_type_id = crm_task_types.id
      FROM crm_task_types
      WHERE crm_task_types.account_id = crm_tasks.account_id
        AND crm_task_types.code = crm_tasks.activity_type
        AND crm_tasks.task_type_id IS NULL
    SQL
    execute <<~SQL.squish
      UPDATE crm_tasks
      SET task_outcome_id = crm_task_outcomes.id
      FROM crm_task_outcomes
      WHERE crm_task_outcomes.account_id = crm_tasks.account_id
        AND crm_task_outcomes.task_type_id = crm_tasks.task_type_id
        AND crm_task_outcomes.code = crm_tasks.outcome
        AND crm_tasks.task_outcome_id IS NULL
    SQL
  end

  def expand_deal_waiting
    add_column_if_missing(:crm_deals, :waiting_until, :datetime)
    add_column_if_missing(:crm_deals, :waiting_reason, :text)
    add_column_if_missing(:crm_deals, :waiting_started_at, :datetime)
    add_reference_if_missing(:crm_deals, :waiting_set_by, foreign_key: { to_table: :users, on_delete: :nullify })
    add_index_if_missing(:crm_deals, %i[account_id waiting_until],
                         where: 'waiting_until IS NOT NULL AND archived_at IS NULL',
                         name: 'index_crm_deals_on_active_waiting_until')
    add_check_constraint_if_missing(
      :crm_deals,
      <<~SQL.squish,
        (waiting_until IS NULL AND waiting_reason IS NULL AND waiting_started_at IS NULL) OR
        (waiting_until IS NOT NULL AND LENGTH(BTRIM(waiting_reason)) > 0 AND waiting_started_at IS NOT NULL)
      SQL
      'crm_deals_waiting_state_complete'
    )
  end

  def expand_stage_entry_rules
    add_column_if_missing(:crm_pipelines, :restrict_stage_skipping, :boolean, default: false, null: false)
    add_column_if_missing(:crm_pipelines, :restrict_backward_move, :boolean, default: false, null: false)
    add_column_if_missing(:crm_pipelines, :allow_stage_rule_override, :boolean, default: false, null: false)
    return if table_exists?(:crm_stage_field_requirements)

    create_table :crm_stage_field_requirements do |t|
      t.references :account, null: false, foreign_key: true
      t.references :stage, null: false, foreign_key: { to_table: :crm_stages }
      t.references :field_definition, null: true, foreign_key: { to_table: :crm_field_definitions }
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

  def expand_event_envelopes
    add_column_if_missing(:crm_events, :source, :string, default: 'system', null: false)
    add_column_if_missing(:crm_events, :actor_kind, :string)
    add_column_if_missing(:crm_events, :before_data, :jsonb, default: {}, null: false)
    add_column_if_missing(:crm_events, :after_data, :jsonb, default: {}, null: false)
    add_column_if_missing(:crm_events, :correlation_id, :uuid, default: -> { 'gen_random_uuid()' }, null: false)
    add_column_if_missing(:crm_events, :causation_id, :uuid)
    add_column_if_missing(:crm_events, :schema_version, :integer, default: 1, null: false)
    add_column_if_missing(:crm_events, :command_key, :string)
    add_column_if_missing(:crm_events, :performed_by_type, :string)
    add_column_if_missing(:crm_events, :performed_by_id, :bigint)
    add_column_if_missing(:crm_events, :published_at, :datetime)
    add_column_if_missing(:crm_events, :publication_attempts, :integer, default: 0, null: false)
    add_column_if_missing(:crm_events, :publication_error, :text)
    add_column_if_missing(:crm_events, :publication_next_attempt_at, :datetime,
                          default: -> { 'CURRENT_TIMESTAMP' }, null: false)

    execute <<~SQL.squish
      UPDATE crm_events
      SET published_at = created_at
      WHERE published_at IS NULL
    SQL

    add_index_if_missing(:crm_events, %i[account_id correlation_id])
    add_index_if_missing(:crm_events, %i[published_at id],
                         where: 'published_at IS NULL',
                         name: 'index_crm_events_on_unpublished')
    add_index_if_missing(:crm_events, [:publication_next_attempt_at, :id],
                         where: 'published_at IS NULL',
                         name: 'idx_crm_events_ready_for_publication')
    add_index_if_missing(
      :crm_events,
      %i[account_id eventable_type eventable_id event_type command_key],
      unique: true,
      where: 'command_key IS NOT NULL',
      name: 'index_crm_events_on_command_dedupe'
    )
  end

  def create_stage_visits
    unless table_exists?(:crm_stage_visits)
      create_table :crm_stage_visits do |t|
        t.references :account, null: false, foreign_key: true
        t.references :deal, null: false, foreign_key: { to_table: :crm_deals }
        t.references :pipeline, null: false, foreign_key: { to_table: :crm_pipelines }
        t.references :stage, null: false, foreign_key: { to_table: :crm_stages }
        t.datetime :entered_at, null: false
        t.datetime :exited_at
        t.boolean :estimated, null: false, default: false
        t.datetime :reliable_since, null: false
        t.string :pipeline_name, null: false
        t.string :stage_name, null: false
        t.string :stage_outcome, null: false
        t.uuid :correlation_id, null: false, default: -> { 'gen_random_uuid()' }
        t.bigint :owner_id_at_terminal
        t.bigint :team_id_at_terminal
        t.integer :terminal_attribution_version
        t.timestamps
      end
    end

    add_index_if_missing(:crm_stage_visits, :deal_id,
                         unique: true,
                         where: 'exited_at IS NULL',
                         name: 'index_crm_stage_visits_on_active_deal')
    add_index_if_missing(:crm_stage_visits, %i[account_id entered_at])
    add_index_if_missing(:crm_stage_visits, :correlation_id)
    add_check_constraint_if_missing(
      :crm_stage_visits,
      'exited_at IS NULL OR exited_at >= entered_at',
      'crm_stage_visits_valid_interval'
    )
    add_check_constraint_if_missing(
      :crm_stage_visits,
      <<~SQL.squish,
        (terminal_attribution_version IS NULL AND owner_id_at_terminal IS NULL AND team_id_at_terminal IS NULL)
        OR (terminal_attribution_version = 1 AND stage_outcome IN ('won', 'lost'))
      SQL
      'crm_stage_visits_terminal_attribution_valid'
    )

    reliable_since = connection.quote(Time.current)
    execute <<~SQL.squish
      INSERT INTO crm_stage_visits (
        account_id, deal_id, pipeline_id, stage_id, entered_at, estimated,
        reliable_since, pipeline_name, stage_name, stage_outcome,
        correlation_id, created_at, updated_at
      )
      SELECT deals.account_id, deals.id, deals.pipeline_id, deals.stage_id,
        #{reliable_since}, TRUE, #{reliable_since}, pipelines.name, stages.name,
        stages.outcome, gen_random_uuid(), #{reliable_since}, #{reliable_since}
      FROM crm_deals deals
      INNER JOIN crm_pipelines pipelines ON pipelines.id = deals.pipeline_id
      INNER JOIN crm_stages stages ON stages.id = deals.stage_id
      WHERE NOT EXISTS (
        SELECT 1 FROM crm_stage_visits visits
        WHERE visits.deal_id = deals.id AND visits.exited_at IS NULL
      )
    SQL
  end

  def add_reference_if_missing(table, name, **options)
    add_reference(table, name, **options) unless column_exists?(table, :"#{name}_id")
  end

  def add_column_if_missing(table, name, type, **options)
    add_column(table, name, type, **options) unless column_exists?(table, name)
  end

  def add_index_if_missing(table, columns, **options)
    add_index(table, columns, **options) unless index_exists?(table, columns, name: options[:name])
  end

  def add_check_constraint_if_missing(table, expression, name)
    add_check_constraint(table, expression, name: name) unless check_constraint_exists?(table, name: name)
  end
end
