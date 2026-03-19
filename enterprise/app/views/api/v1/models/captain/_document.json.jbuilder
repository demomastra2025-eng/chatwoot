json.account_id resource.account_id
json.assistant do
  json.partial! 'api/v1/models/captain/assistant', formats: [:json], resource: resource.assistant
end
json.content resource.content
json.content_type resource.content_type
json.created_at resource.created_at.to_i
json.external_link resource.external_link
json.display_url resource.display_url
json.failed_urls_count resource.failed_urls_count
json.file_size resource.file_size
json.id resource.id
json.last_error resource.last_error
json.last_synced_at resource.last_synced_at&.to_i
json.name resource.name
json.pages_processed resource.pages_processed
json.pages_total resource.pages_total
json.refresh_mode resource.refresh_mode
json.selected_urls_count resource.selected_urls_count
json.source_document resource.source_document?
json.source_mode resource.source_mode
json.status resource.status
json.sync_status resource.sync_status
json.updated_at resource.updated_at.to_i
