# frozen_string_literal: true

require 'digest'

class MigrateConversationStatusReasonsToCaptainOutcomes < ActiveRecord::Migration[7.0]
  class MigrationAccount < ApplicationRecord
    self.table_name = 'accounts'
  end

  class MigrationAssistant < ApplicationRecord
    self.table_name = 'captain_assistants'
  end

  def up
    MigrationAccount.where("settings ? 'conversation_status_reason_config'").find_each do |account|
      settings = account.settings.to_h.deep_stringify_keys
      legacy_config = settings.delete('conversation_status_reason_config').to_h.deep_stringify_keys
      migrate_assistants!(account.id, legacy_config)
      account.update_columns(settings: settings, updated_at: Time.current)
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Legacy workspace status reasons were removed after migration to Captain outcomes'
  end

  private

  def migrate_assistants!(account_id, legacy_config)
    completion_labels = reason_labels(legacy_config.dig('resolved', 'options'))
    handoff_labels = reason_labels(
      Array(legacy_config.dig('open', 'options')) + Array(legacy_config.dig('pending', 'options'))
    )

    MigrationAssistant.where(account_id: account_id).find_each do |assistant|
      config = assistant.config.to_h.deep_stringify_keys
      outcome_settings = config['outcome_reason_settings'].to_h.deep_stringify_keys

      unless outcome_settings.key?('completion_reasons')
        if completion_labels.present?
          outcome_settings['completion_reasons'] = outcome_reasons(completion_labels)
        else
          config['auto_completion_enabled'] = false
        end
      end
      unless outcome_settings.key?('handoff_reasons')
        outcome_settings['handoff_reasons'] = outcome_reasons(handoff_labels) if handoff_labels.present?
      end

      config['outcome_reason_settings'] = outcome_settings if outcome_settings.present?
      assistant.update_columns(config: config, updated_at: Time.current)
    end
  end

  def reason_labels(values)
    Array(values).filter_map { |value| value.to_s.squish.presence }.uniq(&:downcase).first(19)
  end

  def outcome_reasons(labels)
    labels.map do |label|
      {
        'id' => "legacy_#{Digest::SHA256.hexdigest(label.downcase)[0, 12]}",
        'label' => label.truncate(255),
        'active' => true
      }
    end << { 'id' => 'other', 'label' => 'Other', 'active' => true }
  end
end
