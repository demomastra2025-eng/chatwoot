class ValidateCrmLifecycleConstraints < ActiveRecord::Migration[7.1]
  # Step 6 of the CRM lifecycle expand. VALIDATE CONSTRAINT takes SHARE UPDATE EXCLUSIVE, so reads and writes
  # continue while the existing rows are checked (like 20260928110200). Only constraints that are still NOT VALID are
  # touched, and the scans run without the request statement timeout, which is restored afterwards.
  disable_ddl_transaction!

  STATEMENT_TIMEOUT = '30min'.freeze
  CHECK_CONSTRAINTS = [
    [:crm_tasks, 'crm_tasks_deadline_shape'],
    [:crm_tasks, 'crm_tasks_reschedule_count_non_negative'],
    [:crm_tasks, 'crm_tasks_cancellation_state_complete'],
    [:crm_deals, 'crm_deals_waiting_state_complete'],
    [:crm_stage_visits, 'crm_stage_visits_valid_interval'],
    [:crm_stage_visits, 'crm_stage_visits_terminal_attribution_valid']
  ].freeze
  FOREIGN_KEYS = [
    [:crm_task_types, :account_id],
    [:crm_task_outcomes, :account_id],
    [:crm_task_outcomes, :task_type_id],
    [:crm_stage_field_requirements, :account_id],
    [:crm_stage_field_requirements, :stage_id],
    [:crm_stage_field_requirements, :field_definition_id],
    [:crm_stage_visits, :account_id],
    [:crm_stage_visits, :deal_id],
    [:crm_stage_visits, :pipeline_id],
    [:crm_stage_visits, :stage_id],
    [:crm_tasks, :completed_by_id],
    [:crm_tasks, :cancelled_by_id],
    [:crm_tasks, :task_type_id],
    [:crm_tasks, :task_outcome_id],
    [:crm_deals, :waiting_set_by_id]
  ].freeze

  def up
    without_statement_timeout do
      validate_checks
      validate_keys
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'CRM lifecycle schema is additive; roll back application behavior without removing retained CRM data'
  end

  private

  def validate_checks
    CHECK_CONSTRAINTS.each do |table, name|
      constraint = connection.check_constraints(table).find { |candidate| candidate.name == name }
      next if constraint.nil? || constraint.validate?

      validate_check_constraint table, name: name
    end
  end

  def validate_keys
    FOREIGN_KEYS.each do |table, column|
      foreign_key = connection.foreign_keys(table).find { |candidate| candidate.column == column.to_s }
      next if foreign_key.nil? || foreign_key.validated?

      validate_foreign_key table, name: foreign_key.name
    end
  end

  def without_statement_timeout
    previous = select_value('SHOW statement_timeout')
    execute("SET statement_timeout = '#{STATEMENT_TIMEOUT}'")
    yield
  ensure
    execute("SET statement_timeout = #{quote(previous)}") if previous
  end
end
