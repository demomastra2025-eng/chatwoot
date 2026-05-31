# frozen_string_literal: true

class EnableCompaniesDefaultFeatureFlag < ActiveRecord::Migration[7.1]
  FEATURE_NAME = 'companies'

  def up
    feature_defaults = YAML.safe_load(Rails.root.join('config/features.yml').read)
    company_feature = feature_defaults.find { |feature| feature['name'] == FEATURE_NAME }

    upsert_account_default(company_feature) if company_feature.present?

    Account.reset_column_information
    Account.find_each(batch_size: 100) do |account|
      account.enable_features!(FEATURE_NAME)
    end
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
end
