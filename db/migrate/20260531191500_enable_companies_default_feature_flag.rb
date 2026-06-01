# frozen_string_literal: true

class EnableCompaniesDefaultFeatureFlag < ActiveRecord::Migration[7.1]
  FEATURE_NAME = 'companies'

  def up
    feature_defaults = YAML.safe_load(Rails.root.join('config/features.yml').read)
    company_feature = feature_defaults.find { |feature| feature['name'] == FEATURE_NAME }

    upsert_account_default(company_feature) if company_feature.present?

    enable_account_feature_flag
  end

  def down
    config = InstallationConfig.find_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS')
    return if config.blank?

    config.value = Array(config.value).reject { |feature| feature['name'] == FEATURE_NAME }
    config.save!
  end

  private

  def upsert_account_default(company_feature)
    config = InstallationConfig.find_or_initialize_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS')
    features = Array(config.value).index_by { |feature| feature['name'] }
    features[FEATURE_NAME] = company_feature

    config.value = features.values
    config.locked = true if config.locked.nil?
    config.save!
  end

  def enable_account_feature_flag
    position = Featurable::FEATURE_POSITIONS.fetch(FEATURE_NAME)
    flag_value = 1 << (position - 1)

    execute(<<~SQL.squish)
      UPDATE accounts
      SET feature_flags = COALESCE(feature_flags, 0)::bigint | #{flag_value}
    SQL
  end
end
