json.array! @context_fields do |field|
  json.id field[:id]
  json.title field[:title]
  json.group_name field[:group_name]
  json.table_name field[:table_name]
  json.field_type field[:field_type]
  json.field_key field[:field_key]
  json.description field[:description]
  json.selected field[:selected]
end
