class AddDueOnAndScheduleTimezoneToCrmTasks < ActiveRecord::Migration[7.1]
  DEFAULT_TIMEZONE = 'Asia/Almaty'.freeze

  def up
    add_deadline_columns
    backfill_schedule_timezones
    backfill_all_day_deadlines
    enforce_schedule_timezone

    add_index :crm_tasks, %i[account_id due_on],
              where: 'archived_at IS NULL',
              name: 'index_crm_tasks_on_active_due_on'
  end

  def down
    execute <<~SQL.squish
      UPDATE crm_tasks
      SET due_at = (
        (due_on::timestamp + INTERVAL '12 hours') AT TIME ZONE schedule_timezone
      ) AT TIME ZONE 'UTC'
      WHERE all_day = TRUE AND due_on IS NOT NULL AND due_at IS NULL
    SQL

    remove_index :crm_tasks, name: 'index_crm_tasks_on_active_due_on'
    remove_column :crm_tasks, :schedule_timezone
    remove_column :crm_tasks, :due_on
  end

  private

  def add_deadline_columns
    add_column :crm_tasks, :due_on, :date
    add_column :crm_tasks, :schedule_timezone, :string
  end

  def backfill_schedule_timezones
    timezone_backfill = execute <<~SQL.squish
      UPDATE crm_tasks
      SET schedule_timezone = COALESCE(
        (
          SELECT pg_timezone_names.name
          FROM pg_timezone_names
          WHERE pg_timezone_names.name = NULLIF(accounts.settings ->> 'workspace_timezone', '')
          LIMIT 1
        ),
        '#{DEFAULT_TIMEZONE}'
      )
      FROM accounts
      WHERE accounts.id = crm_tasks.account_id
    SQL
    say "Backfilled timezone for #{timezone_backfill.cmd_tuples} tasks"
  end

  def backfill_all_day_deadlines
    deadline_backfill = execute <<~SQL.squish
      UPDATE crm_tasks
      SET due_on = ((due_at AT TIME ZONE 'UTC') AT TIME ZONE schedule_timezone)::date,
          due_at = NULL,
          start_at = NULL
      WHERE all_day = TRUE AND due_at IS NOT NULL
    SQL
    say "Converted #{deadline_backfill.cmd_tuples} all-day deadlines to dates"
  end

  def enforce_schedule_timezone
    change_column_default :crm_tasks, :schedule_timezone, from: nil, to: DEFAULT_TIMEZONE
    change_column_null :crm_tasks, :schedule_timezone, false
  end
end
