class EnforceUniqueTerminalCrmStages < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = 'index_crm_stages_on_pipeline_unique_active_terminal'.freeze

  def up
    duplicates = execute(<<~SQL.squish).to_a
      SELECT pipeline_id, outcome, COUNT(*) AS count
      FROM crm_stages
      WHERE active = TRUE AND outcome IN ('won', 'lost')
      GROUP BY pipeline_id, outcome
      HAVING COUNT(*) > 1
    SQL
    if duplicates.any?
      raise ActiveRecord::MigrationError,
            "Duplicate active terminal CRM stages must be resolved first: #{duplicates.inspect}"
    end

    add_index :crm_stages,
              [:pipeline_id, :outcome],
              unique: true,
              where: "active = TRUE AND outcome IN ('won', 'lost')",
              name: INDEX_NAME,
              algorithm: :concurrently
  end

  def down
    remove_index :crm_stages, name: INDEX_NAME, algorithm: :concurrently
  end
end
