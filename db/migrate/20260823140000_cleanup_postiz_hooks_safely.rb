class CleanupPostizHooksSafely < ActiveRecord::Migration[7.1]
  REMOVED_APP_ID = 'postiz'.freeze
  POSTIZ_TOMBSTONE_CONSTRAINT = 'integrations_hooks_app_id_not_postiz'.freeze

  def up
    deleted_hooks = Integrations::Hook.where(app_id: REMOVED_APP_ID).delete_all
    say "Removed #{deleted_hooks} Postiz integration hook(s)"
    return if check_constraint_exists?(:integrations_hooks, name: POSTIZ_TOMBSTONE_CONSTRAINT)

    add_check_constraint :integrations_hooks,
                         "app_id <> '#{REMOVED_APP_ID}'",
                         name: POSTIZ_TOMBSTONE_CONSTRAINT,
                         validate: false
    validate_check_constraint :integrations_hooks, name: POSTIZ_TOMBSTONE_CONSTRAINT
  end

  def down
    say 'Postiz hook cleanup is intentionally irreversible; the historical tombstone remains in place.'
  end
end
