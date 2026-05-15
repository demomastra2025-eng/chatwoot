class Captain::Copilot::ToolCatalog
  class << self
    def tools
      Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT)
    end

    def tools_for(assistant)
      Captain::ToolCatalog.available_tools_for(assistant, Captain::ToolAccess::SCOPE_ASSISTANT)
    end

    def build_tool(tool_definition, assistant:, user: nil, conversation: nil, copilot_thread: nil)
      Captain::ToolCatalog.build_tool(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
        user: user,
        conversation: conversation,
        copilot_thread: copilot_thread
      )
    end
  end
end
