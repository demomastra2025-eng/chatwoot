# frozen_string_literal: true

class EnableSchedulingDefaultFeatureFlags < ActiveRecord::Migration[7.1]
  def up
    feature_defaults = YAML.safe_load(Rails.root.join('config/features.yml').read)
    required_features = feature_defaults.select { |feature| feature['name'].in?(%w[scheduling scheduling_finance]) }

    config = InstallationConfig.find_or_initialize_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS')
    config.value = merge_features(config.value, required_features)
    config.locked = true if config.locked.nil?
    config.save!
  end

  def down
    config = InstallationConfig.find_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS')
    return if config.blank?

    config.value = Array(config.value).reject { |feature| feature['name'].in?(%w[scheduling scheduling_finance]) }
    config.save!
  end

  private

  def merge_features(existing_value, required_features)
    existing_by_name = Array(existing_value).index_by { |feature| feature['name'] }

    required_features.each do |feature|
      existing_by_name[feature['name']] = feature
    end

    existing_by_name.values
  end
end
