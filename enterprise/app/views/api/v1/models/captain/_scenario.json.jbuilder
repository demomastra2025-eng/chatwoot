json.id scenario.id
standalone_agent = scenario.standalone_agent
json.title standalone_agent&.name || scenario.title
json.description standalone_agent ? standalone_agent.routing_description : scenario.description
json.instruction standalone_agent ? standalone_agent.description : scenario.instruction
json.tools scenario.tools
json.enabled standalone_agent ? standalone_agent.active? : scenario.enabled
json.standalone_agent_id standalone_agent&.id
json.assistant_id scenario.assistant_id
json.account_id scenario.account_id
json.created_at scenario.created_at
json.updated_at scenario.updated_at
if scenario.assistant.present?
  json.assistant do
    json.id scenario.assistant.id
    json.name scenario.assistant.name
  end
end
