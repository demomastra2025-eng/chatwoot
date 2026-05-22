class Api::V1::Accounts::Content::ChannelsController < Api::V1::Accounts::Content::BaseController
  def index
    render_payload(postiz_client.list_integrations)
  end

  def oauth_url
    provider = params.require(:provider)
    render_payload(postiz_client.oauth_url(provider, refresh: params[:refresh]))
  end

  def destroy
    render_payload(postiz_client.delete_integration(params.require(:id)))
  end

  def find_slot
    render_payload(postiz_client.find_slot(params.require(:id)))
  end
end
