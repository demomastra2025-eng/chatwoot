class Api::V1::Accounts::Telephony::WebphoneController < Api::V1::Accounts::Telephony::BaseController
  def create
    inbox = Current.account.inboxes.find_by(id: params[:inbox_id]) if params[:inbox_id].present?
    authorize inbox, :show? if inbox.present?

    render_payload(webphone_service.token_for(user: Current.user, inbox: inbox))
  end

  def presence
    render_payload(
      webphone_service.update_presence!(
        user: Current.user,
        registered: ActiveModel::Type::Boolean.new.cast(params.require(:registered))
      )
    )
  end

  def claim
    render_payload(
      Telephony::OperatorCallClaimService.new(
        account: Current.account,
        user: Current.user,
        call_ref: params.require(:call_ref)
      ).perform
    )
  end

  def reject
    render_payload(
      Telephony::OperatorCallRejectService.new(
        account: Current.account,
        user: Current.user,
        call_ref: params.require(:call_ref),
        status: params[:status],
        reason: params[:reason]
      ).perform
    )
  end

  private

  def webphone_service
    @webphone_service ||= Telephony::WebphoneService.new(account: Current.account)
  end
end
