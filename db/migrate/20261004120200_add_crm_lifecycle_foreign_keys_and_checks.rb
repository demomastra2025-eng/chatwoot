class AddCrmLifecycleForeignKeysAndChecks < ActiveRecord::Migration[7.1]
  # Step 3 of the CRM lifecycle expand. A foreign key or CHECK constraint added NOT VALID needs only a brief lock
  # and scans nothing; each one runs in its own short transaction under a lock timeout (retried), exactly like
  # 20260928110050, so a long transaction on users, accounts or a CRM table cannot queue writers behind it. The rows
  # are checked afterwards by 20261004120500 under SHARE UPDATE EXCLUSIVE, which lets reads and writes continue.
  disable_ddl_transaction!

  LOCK_TIMEOUT = '5s'.freeze
  LOCK_ATTEMPTS = 5
  DEADLINE_SHAPE = <<~SQL.squish.freeze
    (
      (all_day = TRUE AND due_on IS NOT NULL AND due_at IS NULL AND start_at IS NULL) OR
      (all_day = FALSE AND due_on IS NULL)
    )
  SQL
  CANCELLATION_STATE = <<~SQL.squish.freeze
    (cancelled_at IS NULL AND cancellation_reason IS NULL) OR
    (cancelled_at IS NOT NULL AND LENGTH(BTRIM(cancellation_reason)) > 0)
  SQL
  WAITING_STATE = <<~SQL.squish.freeze
    (waiting_until IS NULL AND waiting_reason IS NULL AND waiting_started_at IS NULL) OR
    (waiting_until IS NOT NULL AND LENGTH(BTRIM(waiting_reason)) > 0 AND waiting_started_at IS NOT NULL)
  SQL
  TERMINAL_ATTRIBUTION = <<~SQL.squish.freeze
    (terminal_attribution_version IS NULL AND owner_id_at_terminal IS NULL AND team_id_at_terminal IS NULL)
    OR (terminal_attribution_version = 1 AND stage_outcome IN ('won', 'lost'))
  SQL

  FOREIGN_KEYS = [
    [:crm_task_types, :accounts, { column: :account_id }],
    [:crm_task_outcomes, :accounts, { column: :account_id }],
    [:crm_task_outcomes, :crm_task_types, { column: :task_type_id }],
    [:crm_stage_field_requirements, :accounts, { column: :account_id }],
    [:crm_stage_field_requirements, :crm_stages, { column: :stage_id }],
    [:crm_stage_field_requirements, :crm_field_definitions, { column: :field_definition_id }],
    [:crm_stage_visits, :accounts, { column: :account_id }],
    [:crm_stage_visits, :crm_deals, { column: :deal_id }],
    [:crm_stage_visits, :crm_pipelines, { column: :pipeline_id }],
    [:crm_stage_visits, :crm_stages, { column: :stage_id }],
    [:crm_tasks, :users, { column: :completed_by_id, on_delete: :nullify }],
    [:crm_tasks, :users, { column: :cancelled_by_id, on_delete: :nullify }],
    [:crm_tasks, :crm_task_types, { column: :task_type_id }],
    [:crm_tasks, :crm_task_outcomes, { column: :task_outcome_id }],
    [:crm_deals, :users, { column: :waiting_set_by_id, on_delete: :nullify }]
  ].freeze

  CHECK_CONSTRAINTS = [
    [:crm_tasks, 'crm_tasks_deadline_shape', DEADLINE_SHAPE],
    [:crm_tasks, 'crm_tasks_reschedule_count_non_negative', 'reschedule_count >= 0'],
    [:crm_tasks, 'crm_tasks_cancellation_state_complete', CANCELLATION_STATE],
    [:crm_deals, 'crm_deals_waiting_state_complete', WAITING_STATE],
    [:crm_stage_visits, 'crm_stage_visits_valid_interval', 'exited_at IS NULL OR exited_at >= entered_at'],
    [:crm_stage_visits, 'crm_stage_visits_terminal_attribution_valid', TERMINAL_ATTRIBUTION]
  ].freeze

  def up
    FOREIGN_KEYS.each do |from_table, to_table, options|
      with_short_lock_timeout do
        add_foreign_key from_table, to_table, **options, validate: false, if_not_exists: true
      end
    end
    CHECK_CONSTRAINTS.each do |table, name, expression|
      next if check_constraint_exists?(table, name: name)

      with_short_lock_timeout do
        add_check_constraint table, expression, name: name, validate: false
      end
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'CRM lifecycle schema is additive; roll back application behavior without removing retained CRM data'
  end

  private

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
