class AddTeamScopeToScheduling < ActiveRecord::Migration[7.1]
  CAPABILITIES = %w[
    view create update_fields assign delete_archive view_configuration configure export view_reports transition take
    override_schedule complete_cancel view_finance manage_finance
  ].freeze
  APPOINTMENT_CAPABILITIES = %w[
    view create update_fields assign transition delete_archive view_finance manage_finance view_configuration configure export
    view_reports override_schedule
  ].freeze
  SYSTEM_ROLE_FINANCE_GRANTS_SQL = <<~SQL.squish
    INSERT INTO access_role_grants
      (account_id, access_role_id, resource, capability, access_scope, created_at, updated_at)
    SELECT access_roles.account_id,
           access_roles.id,
           'appointments',
           desired.capability,
           desired.access_scope,
           CURRENT_TIMESTAMP,
           CURRENT_TIMESTAMP
    FROM access_roles
    INNER JOIN (
      VALUES
        ('administrator', 'view_finance', 'all'),
        ('administrator', 'manage_finance', 'all'),
        ('department_lead', 'view_finance', 'team')
    ) AS desired(system_key, capability, access_scope)
      ON desired.system_key = access_roles.system_key
    WHERE access_roles.system_key IS NOT NULL
    ON CONFLICT (access_role_id, resource, capability)
    DO UPDATE SET access_scope = EXCLUDED.access_scope, updated_at = CURRENT_TIMESTAMP
  SQL

  def up
    refresh_grant_constraints!(CAPABILITIES, APPOINTMENT_CAPABILITIES)
    backfill_system_role_finance_grants
    add_reference :scheduling_resources, :team, foreign_key: true, index: false
    add_index :scheduling_resources, [:account_id, :team_id], name: 'idx_scheduling_resources_account_team'

    add_reference :scheduling_appointments, :team, foreign_key: true, index: false
    add_index :scheduling_appointments, [:account_id, :team_id], name: 'idx_scheduling_appointments_account_team'

    backfill_resource_teams
    execute <<~SQL.squish
      UPDATE scheduling_appointments
      SET team_id = scheduling_resources.team_id
      FROM scheduling_resources
      WHERE scheduling_resources.id = scheduling_appointments.resource_id
        AND scheduling_resources.account_id = scheduling_appointments.account_id
        AND scheduling_appointments.team_id IS NULL
    SQL
  end

  def down
    remove_reference :scheduling_appointments, :team, foreign_key: true, index: false
    remove_reference :scheduling_resources, :team, foreign_key: true, index: false
    execute <<~SQL.squish
      DELETE FROM access_role_grants
      WHERE resource = 'appointments'
        AND capability IN ('view_finance', 'manage_finance')
    SQL
    refresh_grant_constraints!(CAPABILITIES - %w[view_finance manage_finance], APPOINTMENT_CAPABILITIES - %w[view_finance manage_finance])
  end

  private

  def refresh_grant_constraints!(capabilities, appointment_capabilities)
    remove_check_constraint :access_role_grants, name: 'access_role_grants_supported_resource_capability'
    remove_check_constraint :access_role_grants, name: 'access_role_grants_supported_capability'
    add_check_constraint :access_role_grants,
                         "capability IN (#{quoted_list(capabilities)})",
                         name: 'access_role_grants_supported_capability'
    add_check_constraint :access_role_grants,
                         appointment_resource_capability_expression(appointment_capabilities),
                         name: 'access_role_grants_supported_resource_capability'
  end

  def appointment_resource_capability_expression(appointment_capabilities)
    <<~SQL.squish
      (resource = 'appointments' AND capability IN (#{quoted_list(appointment_capabilities)})) OR
      (resource <> 'appointments' AND (resource, capability) IN (
        ('contacts', 'view'), ('contacts', 'create'), ('contacts', 'update_fields'), ('contacts', 'assign'),
        ('contacts', 'delete_archive'), ('contacts', 'view_configuration'), ('contacts', 'configure'),
        ('contacts', 'export'), ('contacts', 'view_reports'),
        ('conversations', 'view'), ('conversations', 'create'), ('conversations', 'update_fields'),
        ('conversations', 'assign'), ('conversations', 'transition'), ('conversations', 'take'),
        ('conversations', 'delete_archive'), ('conversations', 'view_configuration'), ('conversations', 'configure'),
        ('conversations', 'export'), ('conversations', 'view_reports'),
        ('deals', 'view'), ('deals', 'create'), ('deals', 'update_fields'), ('deals', 'assign'),
        ('deals', 'transition'), ('deals', 'delete_archive'), ('deals', 'view_configuration'),
        ('deals', 'configure'), ('deals', 'export'), ('deals', 'view_reports'),
        ('tasks', 'view'), ('tasks', 'create'), ('tasks', 'update_fields'), ('tasks', 'assign'),
        ('tasks', 'transition'), ('tasks', 'complete_cancel'), ('tasks', 'delete_archive'),
        ('tasks', 'view_configuration'), ('tasks', 'configure'), ('tasks', 'export'), ('tasks', 'view_reports')
      ))
    SQL
  end

  def quoted_list(values)
    values.map { |value| connection.quote(value) }.join(', ')
  end

  def backfill_resource_teams
    execute <<~SQL.squish
      UPDATE scheduling_resources
      SET team_id = unique_memberships.team_id
      FROM (
        SELECT users.account_id, team_members.user_id, MIN(team_members.team_id) AS team_id
        FROM team_members
        INNER JOIN teams ON teams.id = team_members.team_id
        INNER JOIN account_users users
          ON users.user_id = team_members.user_id
         AND users.account_id = teams.account_id
        GROUP BY users.account_id, team_members.user_id
        HAVING COUNT(DISTINCT team_members.team_id) = 1
      ) unique_memberships
      WHERE scheduling_resources.account_id = unique_memberships.account_id
        AND scheduling_resources.user_id = unique_memberships.user_id
        AND scheduling_resources.team_id IS NULL
    SQL
  end

  def backfill_system_role_finance_grants
    execute SYSTEM_ROLE_FINANCE_GRANTS_SQL
  end
end
