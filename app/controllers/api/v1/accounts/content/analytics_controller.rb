class Api::V1::Accounts::Content::AnalyticsController < Api::V1::Accounts::Content::BaseController
  def index
    if params[:post_id].present?
      render_payload(postiz_client.post_analytics(post_id: params[:post_id], date: params[:date]))
      return
    end

    render_payload(postiz_client.analytics(integration: params.require(:integration), date: params[:date]))
  end
end
