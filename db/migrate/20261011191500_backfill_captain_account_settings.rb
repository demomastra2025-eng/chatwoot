class BackfillCaptainAccountSettings < ActiveRecord::Migration[7.2]
  def up
    Account.find_each { |account| Captain::AccountSettingsBackfill.backfill!(account) }
  end

  def down
    # The previous release reads the untouched per-agent values. Keep the new
    # account settings so a rollback and another deploy cannot discard edits.
  end
end
