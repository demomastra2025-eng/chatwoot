json.array! @skills do |skill|
  json.id skill[:id]
  json.title skill[:title]
  json.group_name skill[:group_name]
  json.description skill[:description]
  json.content skill[:content]
  json.scripts skill[:scripts] do |script|
    json.id script[:id]
    json.tool_id script[:tool_id]
    json.title script[:title]
    json.description script[:description]
    json.risk_level script[:risk_level]
    json.requires_confirmation script[:requires_confirmation]
  end
  json.tree skill[:tree]
  json.editable skill[:editable]
  json.source_type skill[:source_type]
  json.source_url skill[:source_url]
  json.workspace_skill_id skill[:workspace_skill_id]
end
