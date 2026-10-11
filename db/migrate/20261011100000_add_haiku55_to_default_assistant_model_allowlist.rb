# frozen_string_literal: true

class AddHaiku55ToDefaultAssistantModelAllowlist < ActiveRecord::Migration[7.1]
  CONFIG_NAME = 'CAPTAIN_ASSISTANT_MODEL_ALLOWLIST'.freeze
  PREVIOUS_DEFAULT_MODELS = %w[
    openai/gpt-6-luna
    openai/gpt-5.6-luna
    openai/gpt-5.4
    openai/gpt-5.4-mini
  ].freeze
  ADDED_MODEL = 'anthropic/claude-haiku-5.5'.freeze

  def up
    config = InstallationConfig.find_by(name: CONFIG_NAME)
    return if config.nil?

    config.with_lock do
      value = config.value
      models = parsed_models(value)
      next unless models == PREVIOUS_DEFAULT_MODELS

      updated_models = models + [ADDED_MODEL]
      config.update!(value: value.is_a?(String) ? JSON.generate(updated_models) : updated_models)
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'The new model may have been explicitly adopted by an administrator or an agent'
  end

  private

  def parsed_models(value)
    value.is_a?(String) ? JSON.parse(value) : value
  rescue JSON::ParserError
    nil
  end
end
