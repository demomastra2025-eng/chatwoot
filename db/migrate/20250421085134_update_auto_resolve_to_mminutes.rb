class UpdateAutoResolveToMminutes < ActiveRecord::Migration[7.0]
  def up
    # The current Account model requires columns that do not exist at this point in a fresh replay.
    ensure_settings_are_objects!

    execute <<~SQL.squish
      UPDATE accounts
      SET settings = jsonb_set(
        COALESCE(NULLIF(settings, 'null'::jsonb), '{}'::jsonb),
        '{auto_resolve_after}',
        to_jsonb(auto_resolve_duration::bigint * 1440)
      ), updated_at = NOW()
      WHERE auto_resolve_duration IS NOT NULL
        AND settings -> 'auto_resolve_after' IS DISTINCT FROM to_jsonb(auto_resolve_duration::bigint * 1440)
    SQL
  end

  private

  def ensure_settings_are_objects!
    invalid_settings = connection.select_one(<<~SQL.squish)
      SELECT id, jsonb_typeof(settings) AS settings_type
      FROM accounts
      WHERE auto_resolve_duration IS NOT NULL
        AND settings IS NOT NULL
        AND jsonb_typeof(settings) NOT IN ('object', 'null')
      ORDER BY id
      LIMIT 1
    SQL
    return unless invalid_settings

    raise ActiveRecord::MigrationError,
          "Cannot convert auto_resolve_duration for account #{invalid_settings['id']}: " \
          "settings must be a JSON object or null (got #{invalid_settings['settings_type']})"
  end
end
