class RemoveLegacyCaptainContactAttributeFlag < ActiveRecord::Migration[7.0]
  class MigrationCaptainAssistant < ApplicationRecord
    self.table_name = 'captain_assistants'
  end

  def up
    MigrationCaptainAssistant.find_each do |assistant|
      next unless assistant.config.is_a?(Hash)
      next unless assistant.config.key?('feature_contact_attributes') || assistant.config.key?(:feature_contact_attributes)

      normalized_config = assistant.config.deep_stringify_keys
      normalized_config.delete('feature_contact_attributes')
      assistant.update_columns(config: normalized_config, updated_at: Time.current)
    end
  end

  def down
    # No-op: legacy compatibility key intentionally removed.
  end
end
