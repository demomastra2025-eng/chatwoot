class EnforceCrmTaskDeadlineShape < ActiveRecord::Migration[7.1]
  CONSTRAINT_NAME = 'crm_tasks_deadline_shape'.freeze
  DEADLINE_SHAPE = <<~SQL.squish.freeze
    (
      (all_day = TRUE AND due_on IS NOT NULL AND due_at IS NULL AND start_at IS NULL) OR
      (all_day = FALSE AND due_on IS NULL)
    )
  SQL

  def up
    normalize_all_day_flags
    clear_timed_dates
    clear_all_day_timestamps

    add_check_constraint :crm_tasks,
                         DEADLINE_SHAPE,
                         name: CONSTRAINT_NAME,
                         validate: false
    validate_check_constraint :crm_tasks, name: CONSTRAINT_NAME
  end

  def down
    remove_check_constraint :crm_tasks, name: CONSTRAINT_NAME
  end

  private

  def normalize_all_day_flags
    reset_all_day = execute <<~SQL.squish
      UPDATE crm_tasks
      SET all_day = FALSE
      WHERE all_day = TRUE AND due_on IS NULL
    SQL
    say "Normalized #{reset_all_day.cmd_tuples} all-day tasks without a date"
  end

  def clear_timed_dates
    cleared_timed_dates = execute <<~SQL.squish
      UPDATE crm_tasks
      SET due_on = NULL
      WHERE all_day = FALSE AND due_on IS NOT NULL
    SQL
    say "Cleared date-only deadlines from #{cleared_timed_dates.cmd_tuples} timed tasks"
  end

  def clear_all_day_timestamps
    normalized_all_day = execute <<~SQL.squish
      UPDATE crm_tasks
      SET due_at = NULL, start_at = NULL
      WHERE all_day = TRUE AND (due_at IS NOT NULL OR start_at IS NOT NULL)
    SQL
    say "Cleared timestamps from #{normalized_all_day.cmd_tuples} all-day tasks"
  end
end
