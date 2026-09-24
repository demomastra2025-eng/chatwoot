class FlipChatwootV4DefaultFeatureFlagInstallationConfig < ActiveRecord::Migration[7.0]
  # chatwoot_v4 is the 38th flag in the original account bitmask.
  CHATWOOT_V4_FLAG = 1 << 37

  def up
    # Update the default feature flag config to enable chatwoot_v4
    config = InstallationConfig.find_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS')
    if config && config.value.present?
      features = config.value.map do |f|
        if f['name'] == 'chatwoot_v4'
          f.merge('enabled' => true)
        else
          f
        end
      end
      config.value = features
      config.save!
    end

    # Do not load the current Account model against this historical schema.
    execute <<~SQL.squish
      UPDATE accounts SET feature_flags = feature_flags | #{CHATWOOT_V4_FLAG}
      WHERE (feature_flags & #{CHATWOOT_V4_FLAG}) = 0
    SQL

    GlobalConfig.clear_cache
  end
end
