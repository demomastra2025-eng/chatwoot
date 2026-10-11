# frozen_string_literal: true

class MergeCaptainAgentRulesIntoPrompts < ActiveRecord::Migration[7.1]
  class LegacyAssistant < ActiveRecord::Base
    self.table_name = 'captain_assistants'
  end

  def up
    return unless table_exists?(:captain_assistants)

    LegacyAssistant.find_each do |assistant|
      Captain::Assistant::MergeLegacyRulesService.new(assistant: assistant).perform
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Agent rules were preserved in the editable main prompt.'
  end
end
