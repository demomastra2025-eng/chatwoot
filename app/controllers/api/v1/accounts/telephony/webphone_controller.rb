class Api::V1::Accounts::Telephony::WebphoneController < Api::V1::Accounts::Telephony::BaseController
  def create
    inbox = Current.account.inboxes.find_by(id: params[:inbox_id]) if params[:inbox_id].present?
    authorize inbox, :show? if inbox.present?

    render_payload(webphone_service.token_for(user: Current.user, inbox: inbox))
  end

  private

  def webphone_service
    @webphone_service ||= Telephony::WebphoneService.new(account: Current.account)
  end
end
