class AddDefaultToCrmStages < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  DEFAULT_INDEX_NAME = 'index_crm_stages_on_pipeline_default_active'.freeze
  DEFAULT_CHECK_NAME = 'crm_stages_default_active_open'.freeze

  def up
    add_column :crm_stages, :default, :boolean, default: false, null: false

    execute <<~SQL.squish
      UPDATE crm_stages
      SET "default" = TRUE
      WHERE id IN (
        SELECT DISTINCT ON (pipeline_id) id
        FROM crm_stages
        WHERE active = TRUE AND outcome = 'open'
        ORDER BY pipeline_id, position ASC, id ASC
      )
    SQL

    add_check_constraint(
      :crm_stages,
      'NOT "default" OR (active = TRUE AND outcome = \'open\')',
      name: DEFAULT_CHECK_NAME,
      validate: false
    )
    validate_check_constraint :crm_stages, name: DEFAULT_CHECK_NAME

    add_index :crm_stages,
              [:pipeline_id],
              unique: true,
              where: '"default" = true AND active = true',
              name: DEFAULT_INDEX_NAME,
              algorithm: :concurrently
  end

  def down
    if index_exists?(:crm_stages, name: DEFAULT_INDEX_NAME)
      remove_index :crm_stages,
                   name: DEFAULT_INDEX_NAME,
                   algorithm: :concurrently
    end

    remove_check_constraint :crm_stages, name: DEFAULT_CHECK_NAME if check_constraint_exists?(:crm_stages, name: DEFAULT_CHECK_NAME)

    remove_column :crm_stages, :default
  end
end
