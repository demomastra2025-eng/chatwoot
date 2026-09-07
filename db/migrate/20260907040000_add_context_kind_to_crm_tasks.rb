class AddContextKindToCrmTasks < ActiveRecord::Migration[7.1]
  ALLOWED_CONTEXTS_CONSTRAINT = 'crm_tasks_context_kind_allowed'.freeze
  SALES_DEAL_CONSTRAINT = 'crm_tasks_sales_context_requires_deal'.freeze
  ALLOWED_CONTEXTS_SQL = "context_kind IN ('sales', 'personal')".freeze
  SALES_DEAL_SQL = "context_kind <> 'sales' OR deal_id IS NOT NULL".freeze

  def up
    add_column :crm_tasks, :context_kind, :string

    backfill_context_kind!

    add_check_constraint :crm_tasks,
                         ALLOWED_CONTEXTS_SQL,
                         name: ALLOWED_CONTEXTS_CONSTRAINT,
                         validate: false
    add_check_constraint :crm_tasks,
                         SALES_DEAL_SQL,
                         name: SALES_DEAL_CONSTRAINT,
                         validate: false
    validate_check_constraint :crm_tasks, name: ALLOWED_CONTEXTS_CONSTRAINT
    validate_check_constraint :crm_tasks, name: SALES_DEAL_CONSTRAINT
    change_column_null :crm_tasks, :context_kind, false
  end

  def down
    remove_check_constraint :crm_tasks, name: SALES_DEAL_CONSTRAINT
    remove_check_constraint :crm_tasks, name: ALLOWED_CONTEXTS_CONSTRAINT
    remove_column :crm_tasks, :context_kind
  end

  private

  def backfill_context_kind!
    orphaned_count = count_tasks(<<~SQL.squish)
      deal_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM crm_deals WHERE crm_deals.id = crm_tasks.deal_id
      )
    SQL
    if orphaned_count.positive?
      raise ActiveRecord::MigrationError,
            "Cannot classify CRM task contexts: #{orphaned_count} task(s) reference missing deals"
    end

    sales_count = count_tasks('deal_id IS NOT NULL')
    ambiguous_count = count_tasks('deal_id IS NULL')

    execute <<~SQL.squish
      UPDATE crm_tasks
      SET context_kind = CASE WHEN deal_id IS NULL THEN 'personal' ELSE 'sales' END
      WHERE context_kind IS NULL
    SQL

    say "CRM task context backfill: sales=#{sales_count}, " \
        "ambiguous_without_deal=#{ambiguous_count} (classified personal), orphaned=#{orphaned_count}"
  end

  def count_tasks(condition)
    select_value("SELECT COUNT(*) FROM crm_tasks WHERE #{condition}").to_i
  end
end
