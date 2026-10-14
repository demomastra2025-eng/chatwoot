class AddWorkspaceWorkingHoursInheritanceToInboxes < ActiveRecord::Migration[7.2]
  WorkspaceAccount = Class.new(ActiveRecord::Base) { self.table_name = 'accounts' }
  LegacyInbox = Class.new(ActiveRecord::Base) { self.table_name = 'inboxes' }
  LegacyWorkingHour = Class.new(ActiveRecord::Base) { self.table_name = 'working_hours' }

  WORKING_HOUR_COLUMNS = %i[
    day_of_week closed_all_day open_all_day open_hour open_minutes close_hour close_minutes
  ].freeze

  def up
    unless column_exists?(:inboxes, :inherit_working_hours_from_account)
      add_column :inboxes, :inherit_working_hours_from_account, :boolean, default: true, null: false
    end

    WorkspaceAccount.find_each { |account| copy_enabled_inbox_schedule(account) }
    LegacyInbox.where(inherit_working_hours_from_account: false).find_each do |inbox|
      inbox.update!(inherit_working_hours_from_account: true)
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Workspace schedules preserve legacy inbox data'
  end

  private

  def copy_enabled_inbox_schedule(account)
    return if account.settings.to_h['workspace_working_hours'].present?

    source = LegacyInbox.where(account_id: account.id, working_hours_enabled: true).order(:id).first
    return unless source

    rows = LegacyWorkingHour.where(inbox_id: source.id).order(:day_of_week).pluck(*WORKING_HOUR_COLUMNS)
    return unless rows.size == 7

    schedule = rows.map { |row| WORKING_HOUR_COLUMNS.zip(row).to_h }
    account.update!(settings: account.settings.to_h.merge('workspace_timezone' => source.timezone,
                                                          'workspace_working_hours' => schedule))
  end
end
