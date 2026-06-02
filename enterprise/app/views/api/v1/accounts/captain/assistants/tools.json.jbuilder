json.array! @tools do |tool|
  json.id tool[:id]
  json.title tool[:title]
  json.group_name tool[:group_name]
  json.description tool[:description]
  json.icon tool[:icon]
  json.scope_name tool[:scope_name]
  json.source_type tool[:source_type]
  json.selected tool[:selected] if tool.key?(:selected)
  json.selected_by_default tool[:selected_by_default] if tool.key?(:selected_by_default)
  json.provider tool[:provider]
end
