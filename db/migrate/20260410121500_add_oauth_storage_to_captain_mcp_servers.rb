class AddOauthStorageToCaptainMcpServers < ActiveRecord::Migration[7.1]
  def change
    add_column :captain_mcp_servers, :oauth_token_data, :text
    add_column :captain_mcp_servers, :oauth_client_info_data, :text
    add_column :captain_mcp_servers, :oauth_server_metadata_data, :text
    add_column :captain_mcp_servers, :oauth_pkce_data, :text
    add_column :captain_mcp_servers, :oauth_resource_metadata_data, :text
    add_column :captain_mcp_servers, :oauth_state_param, :string
    add_column :captain_mcp_servers, :oauth_state_expires_at, :datetime
    add_column :captain_mcp_servers, :oauth_return_url, :text
    add_column :captain_mcp_servers, :oauth_last_authorized_at, :datetime

    add_index :captain_mcp_servers, :oauth_state_param, unique: true, where: 'oauth_state_param IS NOT NULL'
  end
end
