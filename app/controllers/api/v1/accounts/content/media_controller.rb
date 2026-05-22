class Api::V1::Accounts::Content::MediaController < Api::V1::Accounts::Content::BaseController
  def create
    render_payload(postiz_client.upload(params.require(:file)), status: :created)
  end

  def upload_from_url
    render_payload(postiz_client.upload_from_url(params.require(:url)), status: :created)
  end
end
