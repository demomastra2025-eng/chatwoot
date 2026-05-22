class Api::V1::Accounts::Content::PostsController < Api::V1::Accounts::Content::BaseController
  def index
    render_payload(
      postiz_client.list_posts(
        start_date: params.require(:startDate),
        end_date: params.require(:endDate),
        customer: params[:customer]
      )
    )
  end

  def create
    render_payload(postiz_client.create_post(post_payload), status: :created)
  end

  def destroy
    render_payload(postiz_client.delete_post(params.require(:id)))
  end

  def status
    render_payload(postiz_client.change_post_status(params.require(:id), params.require(:status)))
  end

  def missing
    render_payload(postiz_client.missing_post(params.require(:id)))
  end

  private

  def post_payload
    params.to_unsafe_h.except('controller', 'action', 'account_id', 'format', 'post')
  end
end
