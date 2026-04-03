class Captain::ToolTraceBuilder
  VERSION = 1
  EVENT_MESSAGES = {
    'start' => 'Using %{tool_name}',
    'complete' => 'Completed %{tool_name}'
  }.freeze

  def self.step(tool_name:, event:, sequence:)
    normalized_tool_name = tool_name.to_s
    normalized_event = event.to_s

    {
      'id' => "#{normalized_tool_name}:#{normalized_event}:#{sequence}",
      'tool_name' => normalized_tool_name,
      'event' => normalized_event,
      'content' => format(EVENT_MESSAGES.fetch(normalized_event), tool_name: normalized_tool_name)
    }
  end

  def self.payload(steps)
    return if steps.blank?

    {
      'version' => VERSION,
      'tool_steps' => steps
    }
  end
end
