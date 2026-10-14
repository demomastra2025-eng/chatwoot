# frozen_string_literal: true

class UseLunaDecisionsForDefaultCustomGuardrails < ActiveRecord::Migration[7.1]
  CONFIG_NAME = 'CAPTAIN_CUSTOM_GUARDRAIL_MODEL'
  OLD_DEFAULT = 'openai/gpt-6-luna'
  NEW_DEFAULT = 'openai/gpt-6-luna-decisions'

  def up
    config = InstallationConfig.find_by(name: CONFIG_NAME)
    return if config.nil?

    config.with_lock do
      config.update!(value: NEW_DEFAULT) if config.value == OLD_DEFAULT
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'The Decisions model may have been explicitly selected by an administrator'
  end
end
