# frozen_string_literal: true

class CleanupTeamsAndCaptainRoutingScopes < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    cleanup_captain_assistant_scopes
    nullify_team_foreign_keys
    cleanup_crm_stage_team_requirements
    cleanup_automation_rules_and_macros
    delete_teams_and_members
  end

  def down
    # Irreversible data cleanup for removed Teams and Captain routing scopes
  end

  private

  def cleanup_captain_assistant_scopes
    return unless table_exists?(:captain_assistants) && column_exists?(:captain_assistants, :config)

    execute <<~SQL.squish
      UPDATE captain_assistants
      SET config = COALESCE(config, '{}'::jsonb) - 'handoff_team_id' - 'booking_scope'
      WHERE config ? 'handoff_team_id' OR config ? 'booking_scope'
    SQL
  end

  def nullify_team_foreign_keys
    {
      conversations: :team_id,
      communication_threads: :team_id,
      crm_deals: :team_id,
      crm_tasks: :team_id,
      crm_stage_visits: :team_id_at_terminal
    }.each do |table_name, column_name|
      next unless table_exists?(table_name) && column_exists?(table_name, column_name)

      execute("UPDATE #{table_name} SET #{column_name} = NULL WHERE #{column_name} IS NOT NULL")
    end

    return unless table_exists?(:account_user_lifecycle_snapshots) && column_exists?(:account_user_lifecycle_snapshots, :team_ids)

    execute <<~SQL.squish
      UPDATE account_user_lifecycle_snapshots
      SET team_ids = '[]'::jsonb
      WHERE team_ids IS DISTINCT FROM '[]'::jsonb
    SQL
  end

  def cleanup_crm_stage_team_requirements
    return unless table_exists?(:crm_stages) && column_exists?(:crm_stages, :entry_requirements)

    execute <<~SQL.squish
      UPDATE crm_stages
      SET entry_requirements = COALESCE(
        (
          SELECT jsonb_agg(elem)
          FROM jsonb_array_elements(
            CASE
              WHEN jsonb_typeof(entry_requirements) = 'array' THEN entry_requirements
              ELSE '[]'::jsonb
            END
          ) AS elem
          WHERE elem != '"team_id"'::jsonb
            AND COALESCE(elem->>'key', elem->>'field', '') != 'team_id'
        ),
        '[]'::jsonb
      )
      WHERE entry_requirements::text LIKE '%team_id%'
    SQL
  end

  def cleanup_automation_rules_and_macros
    team_actions = %w[
      assign_team
      remove_assigned_team
      send_email_to_team
      assign_deal_team
      assign_task_team
    ]

    if table_exists?(:automation_rules)
      AutomationRule.find_each do |rule|
        conditions = Array(rule.conditions).reject { |c| (c['attribute_key'] || c[:attribute_key]).to_s == 'team_id' }
        actions = Array(rule.actions).reject { |a| team_actions.include?((a['action_name'] || a[:action_name]).to_s) }
        next if conditions == rule.conditions && actions == rule.actions

        if conditions.empty? || actions.empty?
          rule.update_columns(
            conditions: conditions,
            actions: actions,
            active: false
          )
        else
          rule.update_columns(conditions: conditions, actions: actions)
        end
      end
    end

    return unless table_exists?(:macros)

    Macro.find_each do |macro|
      actions = Array(macro.actions).reject { |a| team_actions.include?((a['action_name'] || a[:action_name]).to_s) }
      next if actions == macro.actions

      macro.update_columns(actions: actions)
    end
  end

  def delete_teams_and_members
    execute('DELETE FROM team_members') if table_exists?(:team_members)
    execute('DELETE FROM teams') if table_exists?(:teams)
  end
end
