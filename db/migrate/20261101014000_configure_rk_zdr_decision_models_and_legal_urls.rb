# frozen_string_literal: true

class ConfigureRkZdrDecisionModelsAndLegalUrls < ActiveRecord::Migration[7.1]
  OLD_LANGUAGE_MODEL = 'openai/gpt-6-luna-decisions'
  NEW_LANGUAGE_MODEL = 'inception/mercury-decide'
  OLD_DECISION_CHAIN = '["inception/mercury-decide", "microsoft/microsoft-decision-1", "openai/gpt-6-luna-decisions"]'
  NEW_DECISION_CHAIN = '["inception/mercury-decide", "microsoft/microsoft-decision-1", "perplexity/pplx-decider-v1.2"]'
  OLD_LEGAL_URL = 'https://one-link.kz'

  def up
    migrate_default('CAPTAIN_LANGUAGE_DETECTION_MODEL', OLD_LANGUAGE_MODEL, NEW_LANGUAGE_MODEL)
    migrate_default('CAPTAIN_DECISION_MODEL_CHAIN', OLD_DECISION_CHAIN, NEW_DECISION_CHAIN)
    migrate_legal_url('TERMS_URL', '/legal/ru/terms')
    migrate_legal_url('PRIVACY_URL', '/legal/ru/privacy')
    GlobalConfig.clear_cache if defined?(GlobalConfig)
  end

  def down
    migrate_default('CAPTAIN_LANGUAGE_DETECTION_MODEL', NEW_LANGUAGE_MODEL, OLD_LANGUAGE_MODEL)
    migrate_default('CAPTAIN_DECISION_MODEL_CHAIN', NEW_DECISION_CHAIN, OLD_DECISION_CHAIN)
    migrate_default('TERMS_URL', '/legal/ru/terms', OLD_LEGAL_URL)
    migrate_default('PRIVACY_URL', '/legal/ru/privacy', OLD_LEGAL_URL)
    GlobalConfig.clear_cache if defined?(GlobalConfig)
  end

  private

  def migrate_default(name, expected_old, new_value)
    return unless defined?(InstallationConfig) && table_exists?(:installation_configs)

    record = InstallationConfig.find_by(name: name)
    return unless record && record.value == expected_old

    record.update!(value: new_value)
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
