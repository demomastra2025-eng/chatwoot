class AddTerminalAttributionToCrmStageVisits < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  CONSTRAINT_NAME = 'crm_stage_visits_terminal_attribution_valid'.freeze
  ATTRIBUTION_CHECK = <<~SQL.squish
    (terminal_attribution_version IS NULL AND owner_id_at_terminal IS NULL AND team_id_at_terminal IS NULL)
    OR
    (terminal_attribution_version = 1 AND stage_outcome IN ('won', 'lost'))
  SQL

  def up
    add_column :crm_stage_visits, :owner_id_at_terminal, :bigint
    add_column :crm_stage_visits, :team_id_at_terminal, :bigint
    add_column :crm_stage_visits, :terminal_attribution_version, :integer
    add_check_constraint :crm_stage_visits,
                         ATTRIBUTION_CHECK,
                         name: CONSTRAINT_NAME,
                         validate: false
    validate_check_constraint :crm_stage_visits, name: CONSTRAINT_NAME
  end

  def down
    remove_check_constraint :crm_stage_visits, name: CONSTRAINT_NAME
    remove_column :crm_stage_visits, :terminal_attribution_version
    remove_column :crm_stage_visits, :team_id_at_terminal
    remove_column :crm_stage_visits, :owner_id_at_terminal
  end
end
