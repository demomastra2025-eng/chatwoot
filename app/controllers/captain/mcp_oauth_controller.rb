class Captain::McpOauthController < ApplicationController
  def callback
    mcp_server = Captain::McpServer.find_by!(oauth_state_param: params.require(:state))
    raise ActiveRecord::RecordNotFound, 'OAuth state expired' if mcp_server.oauth_state_expires_at.blank? || mcp_server.oauth_state_expires_at.past?

    provider = RubyLLM::MCP::Auth::OAuthProvider.new(
      server_url: mcp_server.server_url,
      redirect_uri: captain_mcp_oauth_callback_url,
      scope: mcp_server.oauth_scope,
      storage: Captain::Mcp::OauthStorage.new(mcp_server)
    )
    provider.complete_authorization_flow(params.require(:code), params.require(:state))

    redirect_after_callback(mcp_server, 'connected')
  rescue StandardError => e
    Rails.logger.warn("#{self.class.name}: OAuth callback failed: #{e.class} #{e.message}")
    return redirect_after_callback(mcp_server, 'error', e.message) if defined?(mcp_server) && mcp_server.present?

    render_callback_page('MCP OAuth failed', e.message, :unprocessable_entity)
  end

  private

  def redirect_after_callback(mcp_server, status, error = nil)
    return_url = mcp_server.oauth_return_url.presence
    Captain::Mcp::OauthStorage.new(mcp_server).delete_state(mcp_server.server_url)

    return render_callback_page('MCP OAuth connected', 'You can close this tab and return to OneLink.', :ok) if return_url.blank?

    redirect_to append_oauth_status(return_url, status, error), allow_other_host: false
  end

  def append_oauth_status(return_url, status, error)
    uri = URI.parse(return_url)
    query = Rack::Utils.parse_nested_query(uri.query)
    query['mcp_oauth'] = status
    query['mcp_oauth_error'] = error if error.present?
    uri.query = query.to_query
    uri.to_s
  end

  def render_callback_page(title, message, status)
    render html: <<~HTML.html_safe, status: status
      <!doctype html>
      <html>
        <head>
          <meta charset="utf-8">
          <title>#{ERB::Util.html_escape(title)}</title>
          <style>
            body { margin: 0; min-height: 100vh; display: grid; place-items: center; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f8fafc; color: #0f172a; }
            main { width: min(520px, calc(100vw - 48px)); border: 1px solid #e2e8f0; border-radius: 18px; background: white; padding: 28px; box-shadow: 0 24px 80px rgba(15, 23, 42, 0.12); }
            h1 { margin: 0 0 8px; font-size: 22px; line-height: 1.25; }
            p { margin: 0; color: #475569; line-height: 1.5; }
          </style>
        </head>
        <body>
          <main>
            <h1>#{ERB::Util.html_escape(title)}</h1>
            <p>#{ERB::Util.html_escape(message)}</p>
          </main>
        </body>
      </html>
    HTML
  end
end
