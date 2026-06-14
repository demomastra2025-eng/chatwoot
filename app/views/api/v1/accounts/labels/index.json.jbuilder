json.payload do
  json.array! @labels do |label|
    json.id label.id
    json.title label.title
    json.display_title label.display_title
    json.description label.description
    json.color label.color
    json.marker_type label.marker_type
    json.emoji label.emoji
    json.show_on_sidebar label.show_on_sidebar
    json.contacts_count @contact_counts_by_label.fetch(label.title, 0)
  end
end
