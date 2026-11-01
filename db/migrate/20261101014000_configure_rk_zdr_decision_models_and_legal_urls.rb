# frozen_string_literal: true

class ConfigureRkZdrDecisionModelsAndLegalUrls < ActiveRecord::Migration[7.1]
  OLD_LEGAL_URL = 'https://one-link.kz'

  def up
    migrate_legal_url('TERMS_URL', '/legal/ru/terms')
    migrate_legal_url('PRIVACY_URL', '/legal/ru/privacy')
    GlobalConfig.clear_cache if defined?(GlobalConfig)
  end

  def down
    revert_legal_url('TERMS_URL', '/legal/ru/terms', OLD_LEGAL_URL)
    revert_legal_url('PRIVACY_URL', '/legal/ru/privacy', OLD_LEGAL_URL)
    GlobalConfig.clear_cache if defined?(GlobalConfig)
  end

  private

  def revert_legal_url(name, expected_current, old_value)
    return unless defined?(InstallationConfig) && table_exists?(:installation_configs)

    record = InstallationConfig.find_by(name: name)
    return unless record && record.value == expected_current

    record.update!(value: old_value)
  end

  def migrate_legal_url(name, new_value)
    return unless defined?(InstallationConfig) && table_exists?(:installation_configs)

    record = InstallationConfig.find_by(name: name)
    return unless record

    val = record.value.to_s.strip
    return unless val.blank? || val == OLD_LEGAL_URL || val.match?(/chatwoot\.com/i)

    record.update!(value: new_value)
  end
end
