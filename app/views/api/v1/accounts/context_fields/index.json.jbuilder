json.array! @context_fields do |field|
  json.id field[:id]
  json.title field[:title]
  json.group_name field[:group_name]
  json.table_name field[:table_name]
  json.field_type field[:field_type]
  json.field_key field[:field_key]
  json.description field[:description]
  json.deprecated field[:deprecated] || false
  json.selectable field[:selectable] != false
  json.replacement_field_id field[:replacement_field_id]
  json.value_type field[:value_type]
  json.summary_version field[:summary_version]
end
