# frozen_string_literal: true

# A handoff target is represented without building its tools or MCP catalog.
# Its full runtime is created only when a turn actually reaches that agent.
class Captain::Runtime::LazyAgent < Captain::Runtime::Agent
  attr_reader :display_name, :routing_description

  def initialize(actor, options: {})
    @actor = actor
    @options = options
    @display_name = actor.name
    @routing_description = actor.routing_description.to_s
    super(name: actor.agent_name)
    self.assistant_id = actor.id
  end

  def model = materialized.model
  def tools = materialized.tools
  def temperature = materialized.temperature
  def response_schema = materialized.response_schema
  def headers = materialized.headers
  def params = materialized.params

  # The ids of the tools the agent will have, read from the assistant without building them.
  def tool_ids
    @tool_ids ||= Array(@actor.selected_agent_tool_ids).map(&:to_s)
  end

  def handoff_team_id = @actor.handoff_team_id
  def handoff_team_name = @actor.handoff_team&.name
  def booking_resource_ids = @actor.booking_resource_ids

  def get_system_prompt(context)
    materialized.get_system_prompt(context)
  end

  private

  def materialized
    @materialized ||= @actor.agent(**@options)
  end
end
