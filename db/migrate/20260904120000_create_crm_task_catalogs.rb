class CreateCrmTaskCatalogs < ActiveRecord::Migration[7.1]
  TYPE_DEFINITIONS = [
    ['task', 'Task', 'i-lucide-list-todo', 1, true],
    ['call', 'Call', 'i-lucide-phone', 2, false],
    ['meeting', 'Meeting', 'i-lucide-users', 3, false],
    ['message', 'Message', 'i-lucide-message-square', 4, false],
    ['touch', 'Touch', 'i-lucide-handshake', 5, false]
  ].freeze
  OUTCOME_DEFINITIONS = {
    'task' => %w[completed not_done cancelled],
    'call' => %w[answered no_answer busy cancelled not_done],
    'meeting' => %w[held cancelled no_show rescheduled not_done],
    'message' => %w[sent failed not_done],
    'touch' => %w[completed no_answer cancelled not_done]
  }.freeze

  def up
    create_task_types
    create_task_outcomes
    add_catalog_references
    backfill_catalogs
    enforce_task_type
  end

  def down
    remove_reference :crm_tasks, :task_outcome, foreign_key: { to_table: :crm_task_outcomes }
    remove_reference :crm_tasks, :task_type, foreign_key: { to_table: :crm_task_types }
    drop_table :crm_task_outcomes
    drop_table :crm_task_types
  end

  private

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

    add_index :crm_task_types, [:account_id, :code], unique: true
    add_index :crm_task_types,
              :account_id,
              unique: true,
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

    add_index :crm_task_outcomes, [:task_type_id, :code], unique: true
    add_index :crm_task_outcomes, [:account_id, :task_type_id]
    add_index :crm_task_outcomes,
              :task_type_id,
              unique: true,
              where: '"default" = TRUE AND active = TRUE',
              name: 'index_crm_task_outcomes_on_type_default'
  end

  def add_catalog_references
    add_reference :crm_tasks, :task_type, foreign_key: { to_table: :crm_task_types }
    add_reference :crm_tasks, :task_outcome, foreign_key: { to_table: :crm_task_outcomes }
  end

  def backfill_catalogs
    now = 'CURRENT_TIMESTAMP'
    seed_task_types(now)
    seed_task_outcomes(now)
    backfill_task_catalog_references
  end

  def seed_task_types(now)
    TYPE_DEFINITIONS.each do |code, name, icon, position, default|
      execute <<~SQL.squish
        INSERT INTO crm_task_types
          (account_id, name, code, icon, position, active, "default", created_at, updated_at)
        SELECT DISTINCT crm_tasks.account_id, #{connection.quote(name)}, #{connection.quote(code)},
          #{connection.quote(icon)}, #{position}, TRUE, #{connection.quote(default)}, #{now}, #{now}
        FROM crm_tasks
        WHERE NOT EXISTS (
          SELECT 1 FROM crm_task_types
          WHERE crm_task_types.account_id = crm_tasks.account_id
            AND crm_task_types.code = #{connection.quote(code)}
        )
      SQL
    end
  end

  def seed_task_outcomes(now)
    OUTCOME_DEFINITIONS.each do |type_code, outcome_codes|
      outcome_codes.each_with_index do |outcome_code, index|
        execute <<~SQL.squish
          INSERT INTO crm_task_outcomes
            (account_id, task_type_id, name, code, position, active, "default", requires_note, created_at, updated_at)
          SELECT crm_task_types.account_id, crm_task_types.id, #{connection.quote(outcome_code.humanize)},
            #{connection.quote(outcome_code)}, #{index + 1}, TRUE, #{connection.quote(index.zero?)},
            #{connection.quote(outcome_code == 'not_done')}, #{now}, #{now}
          FROM crm_task_types
          WHERE crm_task_types.code = #{connection.quote(type_code)}
            AND NOT EXISTS (
              SELECT 1 FROM crm_task_outcomes
              WHERE crm_task_outcomes.task_type_id = crm_task_types.id
                AND crm_task_outcomes.code = #{connection.quote(outcome_code)}
            )
        SQL
      end
    end
  end

  def backfill_task_catalog_references
    execute <<~SQL.squish
      UPDATE crm_tasks
      SET task_type_id = crm_task_types.id
      FROM crm_task_types
      WHERE crm_task_types.account_id = crm_tasks.account_id
        AND crm_task_types.code = crm_tasks.activity_type
    SQL
    execute <<~SQL.squish
      UPDATE crm_tasks
      SET task_outcome_id = crm_task_outcomes.id
      FROM crm_task_outcomes
      WHERE crm_task_outcomes.account_id = crm_tasks.account_id
        AND crm_task_outcomes.task_type_id = crm_tasks.task_type_id
        AND crm_task_outcomes.code = crm_tasks.outcome
    SQL
  end

  def enforce_task_type
    change_column_null :crm_tasks, :task_type_id, false
    add_index :crm_tasks, [:account_id, :task_type_id, :due_at], name: 'index_crm_tasks_on_account_type_due_at'
  end
end
