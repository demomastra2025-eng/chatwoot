json.counts do
  json.all @sidebar_unread_counts[:all]
  json.statuses @sidebar_unread_counts[:statuses]
  json.inboxes @sidebar_unread_counts[:inboxes]
  json.teams @sidebar_unread_counts[:teams]
  json.labels @sidebar_unread_counts[:labels]
end
