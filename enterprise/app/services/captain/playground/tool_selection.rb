class Captain::Playground::ToolSelection
  def self.include?(assistant, tool_id)
    id = tool_id.to_s
    return true if assistant.allowed_agent_tool_ids.include?(id)

    assistant.scenarios.enabled.any? { |scenario| scenario.runtime_tools.any? { |tool| tool[:id].to_s == id } }
  end
end
