json.id mcp_server.id
json.name mcp_server.name
json.slug mcp_server.slug
json.description mcp_server.description
json.transport_type mcp_server.transport_type
json.server_config mcp_server.server_config_for_api(
  include_secrets: local_assigns.fetch(:include_secrets, false)
)
json.allowed_scopes mcp_server.normalized_allowed_scopes
json.request_timeout mcp_server.request_timeout
json.enabled mcp_server.enabled
json.oauth_status mcp_server.oauth_status
json.account_id mcp_server.account_id
json.created_at mcp_server.created_at.to_i
json.updated_at mcp_server.updated_at.to_i
