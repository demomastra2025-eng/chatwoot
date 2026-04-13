require 'ruby_llm/mcp'

class Captain::Mcp::OauthStorage
  STATE_TTL = 15.minutes

  def initialize(mcp_server)
    @mcp_server = mcp_server
  end

  def get_token(server_url)
    return unless matches_server_url?(server_url)

    @mcp_server.reload.oauth_token
  end

  def set_token(server_url, token)
    return unless matches_server_url?(server_url)

    @mcp_server.oauth_token = token
    @mcp_server.save!
  end

  def delete_token(server_url)
    return unless matches_server_url?(server_url)

    @mcp_server.update!(oauth_token_data: nil)
  end

  def get_client_info(server_url)
    return unless matches_server_url?(server_url)

    @mcp_server.reload.oauth_client_info
  end

  def set_client_info(server_url, client_info)
    return unless matches_server_url?(server_url)

    @mcp_server.oauth_client_info = client_info
    @mcp_server.save!
  end

  def get_server_metadata(server_url)
    return unless matches_server_url?(server_url)

    @mcp_server.reload.oauth_server_metadata
  end

  def set_server_metadata(server_url, metadata)
    return unless matches_server_url?(server_url)

    @mcp_server.oauth_server_metadata = metadata
    @mcp_server.save!
  end

  def get_pkce(server_url)
    return unless matches_server_url?(server_url)

    @mcp_server.reload.oauth_pkce
  end

  def set_pkce(server_url, pkce)
    return unless matches_server_url?(server_url)

    @mcp_server.oauth_pkce = pkce
    @mcp_server.save!
  end

  def delete_pkce(server_url)
    return unless matches_server_url?(server_url)

    @mcp_server.update!(oauth_pkce_data: nil)
  end

  def get_state(server_url)
    return unless matches_server_url?(server_url)

    server = @mcp_server.reload
    return if server.oauth_state_expires_at.present? && server.oauth_state_expires_at.past?

    server.oauth_state_param
  end

  def set_state(server_url, state)
    return unless matches_server_url?(server_url)

    @mcp_server.update!(
      oauth_state_param: state,
      oauth_state_expires_at: STATE_TTL.from_now
    )
  end

  def delete_state(server_url)
    return unless matches_server_url?(server_url)

    @mcp_server.update!(
      oauth_state_param: nil,
      oauth_state_expires_at: nil,
      oauth_return_url: nil
    )
  end

  def get_resource_metadata(server_url)
    return unless matches_server_url?(server_url)

    @mcp_server.reload.oauth_resource_metadata
  end

  def set_resource_metadata(server_url, metadata)
    return unless matches_server_url?(server_url)

    @mcp_server.oauth_resource_metadata = metadata
    @mcp_server.save!
  end

  def delete_resource_metadata(server_url)
    return unless matches_server_url?(server_url)

    @mcp_server.update!(oauth_resource_metadata_data: nil)
  end

  private

  def matches_server_url?(server_url)
    normalized(server_url) == normalized(@mcp_server.server_url)
  end

  def normalized(server_url)
    RubyLLM::MCP::Auth::OAuthProvider.normalize_url(server_url.to_s)
  rescue URI::InvalidURIError
    server_url.to_s
  end
end
