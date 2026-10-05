class SeedCrmTaskCatalogs < ActiveRecord::Migration[7.1]
  # Step 4 (catalogs) of the CRM lifecycle expand: the task type and outcome catalogs of accounts that already have tasks, in
  # small per-account transactions (new rows only, no lock on existing tables). Catalogs are seeded only for accounts
  # that have none, so a type an administrator removed stays removed on a re-run, and the seeded names are the system
  # codes: the interface labels system types and outcomes from translations by code and shows a stored name only for
  # types an administrator creates, so no user-visible English text is written here.
  disable_ddl_transaction!

  ACCOUNT_SLICE = 500
  TASK_TYPES = [
    ['task', 'i-lucide-list-todo', 1, true],
    ['call', 'i-lucide-phone', 2, false],
    ['meeting', 'i-lucide-users', 3, false],
    ['message', 'i-lucide-message-square', 4, false],
    ['touch', 'i-lucide-handshake', 5, false]
  ].freeze
  TASK_OUTCOMES = {
    'task' => %w[completed not_done cancelled],
    'call' => %w[answered no_answer busy cancelled not_done],
    'meeting' => %w[held cancelled no_show rescheduled not_done],
    'message' => %w[sent failed not_done],
    'touch' => %w[completed no_answer cancelled not_done]
  }.freeze

  def up
    account_ids = select_values(<<~SQL.squish)
      SELECT DISTINCT crm_tasks.account_id FROM crm_tasks
      WHERE NOT EXISTS (SELECT 1 FROM crm_task_types WHERE crm_task_types.account_id = crm_tasks.account_id)
    SQL
    account_ids.each_slice(ACCOUNT_SLICE) do |slice|
      transaction do
        seed_task_types(slice)
        seed_task_outcomes(slice)
      end
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'CRM lifecycle schema is additive; roll back application behavior without removing retained CRM data'
  end

  private

  def seed_task_types(account_ids)
    types = TASK_TYPES.map do |code, icon, position, default|
      "(#{connection.quote(code)}, #{connection.quote(icon)}, #{position}, #{connection.quote(default)})"
    end
    execute <<~SQL.squish
      INSERT INTO crm_task_types (account_id, name, code, icon, position, active, "default", created_at, updated_at)
      SELECT accounts.id, types.code, types.code, types.icon, types.position, TRUE, types.is_default,
             CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM accounts
      CROSS JOIN (VALUES #{types.join(', ')}) AS types(code, icon, position, is_default)
      WHERE accounts.id IN (#{account_ids.map(&:to_i).join(', ')})
      ON CONFLICT DO NOTHING
    SQL
  end

  def seed_task_outcomes(account_ids)
    outcomes = TASK_OUTCOMES.flat_map do |type_code, codes|
      codes.each_with_index.map do |code, index|
        "(#{connection.quote(type_code)}, #{connection.quote(code)}, #{index + 1}, #{connection.quote(index.zero?)}, " \
          "#{connection.quote(code == 'not_done')})"
      end
    end
    execute <<~SQL.squish
      INSERT INTO crm_task_outcomes
        (account_id, task_type_id, name, code, position, active, "default", requires_note, created_at, updated_at)
      SELECT crm_task_types.account_id, crm_task_types.id, outcomes.code, outcomes.code, outcomes.position, TRUE,
             outcomes.is_default, outcomes.requires_note, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM crm_task_types
      JOIN (VALUES #{outcomes.join(', ')}) AS outcomes(type_code, code, position, is_default, requires_note)
        ON outcomes.type_code = crm_task_types.code
      WHERE crm_task_types.account_id IN (#{account_ids.map(&:to_i).join(', ')})
      ON CONFLICT DO NOTHING
    SQL
  end
end
