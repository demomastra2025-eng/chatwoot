# frozen_string_literal: true

# Short English tool texts for the customer-facing agent runtime, read once from config/captain/agent_tool_texts.yml.
#
# Captain::Runtime::ToolWrapper applies them to the built-in registry tools it wraps: the description, the descriptions of the
# top-level parameters and the hidden parameters (left out of the schema the model sees; a hidden parameter that is sent anyway is
# dropped before the tool runs). Everything else keeps its own text: the registry, the Copilot classes, MCP, voice, i18n and the UI
# do not use this file.
module Captain::Runtime::AgentToolTexts
  PATH = Rails.root.join('config/captain/agent_tool_texts.yml').freeze

  Entry = Data.define(:description, :params, :hidden_params)

  class << self
    # The entry of a tool id, or nil when the tool keeps its own text.
    def for_tool(tool_id)
      entries[tool_id.to_s]
    end

    def tool_ids
      entries.keys
    end

    # Forgets the loaded file (specs that swap the file).
    def reset!
      @entries = nil
    end

    private

    def entries
      @entries ||= load_entries
    end

    def load_entries
      document = YAML.safe_load(File.read(PATH, encoding: 'UTF-8'), permitted_classes: [], aliases: false)
      document.to_h.fetch('tools', {}).to_h do |tool_id, attributes|
        [tool_id.to_s, build_entry(attributes.to_h)]
      end.freeze
    rescue Errno::ENOENT, Psych::Exception => e
      Rails.logger.error("[CAPTAIN] Agent tool texts could not be loaded: #{e.class}: #{e.message}")
      {}.freeze
    end

    def build_entry(attributes)
      Entry.new(
        description: attributes['description'].to_s.strip.presence,
        params: attributes.fetch('params', {}).to_h.to_h { |name, text| [name.to_s, text.to_s.strip] }.freeze,
        hidden_params: Array(attributes['hidden_params']).map(&:to_s).freeze
      )
    end
  end
end
