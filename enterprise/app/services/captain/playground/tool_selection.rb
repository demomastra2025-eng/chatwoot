class Captain::Playground::ToolSelection
  def self.include?(assistant, tool_id)
    id = tool_id.to_s
    assistant.allowed_agent_tool_ids.include?(id)
  end
end
