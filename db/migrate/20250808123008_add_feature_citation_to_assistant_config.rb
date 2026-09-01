class AddFeatureCitationToAssistantConfig < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL.squish
      UPDATE captain_assistants
      SET config = COALESCE(config, '{}'::jsonb) || '{"feature_citation": true}'::jsonb
    SQL
  end

  def down
    execute <<~SQL.squish
      UPDATE captain_assistants
      SET config = COALESCE(config, '{}'::jsonb) - 'feature_citation'
    SQL
  end
end
