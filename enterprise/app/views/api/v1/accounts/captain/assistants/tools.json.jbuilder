json.array! @tools do |tool|
  json.id tool[:id]
  json.title tool[:title]
  json.group_name tool[:group_name]
  json.description tool[:description]
  json.icon tool[:icon]
end
