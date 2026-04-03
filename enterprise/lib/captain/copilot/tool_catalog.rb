class Captain::Copilot::ToolCatalog
  class << self
    def tools
      Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT)
    end

    def tools_for(assistant)
      tools + assistant.account.captain_custom_tools.enabled.map(&:to_tool_metadata)
    end

    def build_tool(tool_definition, assistant:, user: nil, conversation: nil)
      if tool_definition[:custom]
        custom_tool = assistant.account.captain_custom_tools.enabled.find_by(slug: tool_definition[:id])
        custom_tool&.copilot_tool(assistant, user: user, conversation: conversation)
      else
        tool_class = Captain::ToolRegistry.resolve_assistant_tool_class(tool_definition[:id])
        tool_class&.new(assistant, user: user, conversation: conversation)
      end
    end
  end
end
