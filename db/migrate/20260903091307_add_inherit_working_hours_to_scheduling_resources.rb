class AddInheritWorkingHoursToSchedulingResources < ActiveRecord::Migration[7.1]
  DEFAULT_TIMEZONE = 'Asia/Almaty'.freeze

  def up
    add_column :scheduling_resources, :inherit_working_hours_from_account, :boolean, default: false, null: false

    execute <<~SQL.squish
      UPDATE scheduling_resources
      SET timezone = COALESCE(
        (
          SELECT pg_timezone_names.name
          FROM pg_timezone_names
          WHERE pg_timezone_names.name = NULLIF(accounts.settings ->> 'workspace_timezone', '')
          LIMIT 1
        ),
        '#{DEFAULT_TIMEZONE}'
      )
      FROM accounts
      WHERE accounts.id = scheduling_resources.account_id
    SQL
  end

  def down
    remove_column :scheduling_resources, :inherit_working_hours_from_account
  end
end
