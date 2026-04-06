# Provides helper methods for working with Captain agent tools including
# tool resolution, text parsing, and metadata retrieval.
module Concerns::CaptainToolsHelpers
  extend ActiveSupport::Concern
  TOOL_REFERENCE_RENDER_REGEX = %r{\[([^\]]+)\]\(tool://([^/)]+)\)}

  # Regular expression pattern for matching tool references in text.
  # Matches patterns like [Tool name](tool://tool_id) following markdown link syntax.
  TOOL_REFERENCE_REGEX = %r{\[[^\]]+\]\(tool://([^/)]+)\)}

  class_methods do
    # Returns all built-in agent tools with their metadata.
    # Only includes tools that have corresponding class files and can be resolved.
    #
    # @return [Array<Hash>] Array of tool hashes with :id, :title, :description, :icon
    def built_in_agent_tools
      Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT)
    end

    # Resolves a tool class from a tool ID.
    # Converts snake_case tool IDs to PascalCase class names and constantizes them.
    #
    # @param tool_id [String] The snake_case tool identifier
    # @return [Class, nil] The tool class if found, nil if not resolvable
    def resolve_tool_class(tool_id)
      Captain::ToolRegistry.resolve_agent_tool_class(tool_id)
    end

    # Returns an array of all built-in tool IDs.
    # Convenience method that extracts just the IDs from built_in_agent_tools.
    #
    # @return [Array<String>] Array of built-in tool IDs
    def built_in_tool_ids
      built_in_agent_tools.map { |tool| tool[:id] }
    end
  end

  # Extracts tool IDs from text containing tool references.
  # Parses text for (tool://tool_id) patterns and returns unique tool IDs.
  #
  # @param text [String] Text to parse for tool references
  # @return [Array<String>] Array of unique tool IDs found in the text
  def extract_tool_ids_from_text(text)
    return [] if text.blank?

    tool_matches = text.scan(TOOL_REFERENCE_REGEX)
    tool_matches.flatten.map { |tool_id| normalize_tool_id(tool_id) }.uniq
  end

  def render_tool_references(text)
    return text if text.blank?

    text.gsub(TOOL_REFERENCE_RENDER_REGEX) do
      label = Regexp.last_match(1).to_s.strip
      tool_id = normalize_tool_id(Regexp.last_match(2))
      reference_name = label.presence || tool_id

      "`#{reference_name}` tool"
    end
  end

  private

  def normalize_tool_id(tool_id)
    tool_id.to_s.gsub(/\\(.)/, '\1')
  end
end
