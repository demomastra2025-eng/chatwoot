class NormalizeCaptainAssistantInstructions < ActiveRecord::Migration[7.0]
  class MigrationAssistant < ApplicationRecord
    self.table_name = 'captain_assistants'
  end

  def up
    MigrationAssistant.reset_column_information

    MigrationAssistant.find_each do |assistant|
      config = assistant.config.is_a?(Hash) ? assistant.config.deep_dup : {}
      legacy_key = assistant.usage_mode == 'internal_assistant' ? 'copilot_instructions' : 'instructions'
      legacy_instruction = config[legacy_key].to_s.strip.presence
      next if legacy_instruction.blank? && !config.key?('instructions') && !config.key?('copilot_instructions')

      merged_description = [assistant.description, legacy_instruction]
                           .filter_map { |value| value.to_s.strip.presence }
                           .uniq
                           .join("\n\n")

      config.delete('instructions')
      config.delete('copilot_instructions')

      assistant.update_columns(
        description: merged_description,
        config: config,
        updated_at: Time.current
      )
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Instruction normalization cannot be reverted safely.'
  end
end
