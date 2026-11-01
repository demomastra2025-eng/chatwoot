class Api::V1::Widget::AvailabilityController < Api::V1::Widget::BaseController
  skip_before_action :set_contact

  def show
    expires_in 1.minute, public: true
    render json: Account::WorkspaceAvailabilitySnapshot.new(account: @web_widget.inbox.account).as_json
  end
end
