# Enable captain_tasks for existing accounts.
# Unlike 20250416182131_flip_chatwoot_v4_default_feature_flag_installation_config.rb,
# we don't need to update ACCOUNT_LEVEL_FEATURE_DEFAULTS or clear GlobalConfig cache
# because captain_tasks already has `enabled: true` in features.yml - ConfigLoader
# handles the defaults on deploy automatically.
class EnableCaptainTasksForExistingAccounts < ActiveRecord::Migration[7.0]
  # captain_tasks is the 61st flag in the original account bitmask.
  CAPTAIN_TASKS_FLAG = 1 << 60

  def up
    # The current Account model requires columns added after this migration.
    execute <<~SQL.squish
      UPDATE accounts
      SET feature_flags = feature_flags | #{CAPTAIN_TASKS_FLAG}, updated_at = NOW()
      WHERE (feature_flags & #{CAPTAIN_TASKS_FLAG}) = 0
    SQL
  end
end
