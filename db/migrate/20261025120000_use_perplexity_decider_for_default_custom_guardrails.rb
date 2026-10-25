# frozen_string_literal: true

# The custom guardrail checks move to Perplexity Decider 1.2 by default (Luna Decisions stays as its fallback decision model, see
# Llm::FeatureProfile). Only an installation still on the previous built-in default is switched; any other choice is kept.
class UsePerplexityDeciderForDefaultCustomGuardrails < ActiveRecord::Migration[7.1]
  CONFIG_NAME = 'CAPTAIN_CUSTOM_GUARDRAIL_MODEL'
  OLD_DEFAULT = 'openai/gpt-6-luna-decisions'
  NEW_DEFAULT = 'perplexity/pplx-decider-v1.2'

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
