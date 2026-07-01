class Api::V1::Accounts::Telephony::WebphoneController < Api::V1::Accounts::Telephony::BaseController
  def create
    inbox = Current.account.inboxes.find_by(id: params[:inbox_id]) if params[:inbox_id].present?
    authorize inbox, :show? if inbox.present?

    render_payload(webphone_service.token_for(user: Current.user, inbox: inbox))
  end

  def presence
    inbox = Current.account.inboxes.find_by(id: params[:inbox_id]) if params[:inbox_id].present?
    authorize inbox, :show? if inbox.present?

    render_payload(
      webphone_service.update_presence!(
        user: Current.user,
        registered: ActiveModel::Type::Boolean.new.cast(params.require(:registered)),
        inbox: inbox
      )
    )
  end

  def incoming
    inbox = Current.account.inboxes.find(params.require(:inbox_id))
    authorize inbox, :show?

    render_payload(
      webphone_service.report_browser_sip_incoming!(
        user: Current.user,
        inbox: inbox,
        params: incoming_params.to_h
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

  def incoming_params
    params.permit(
      :provider,
      :call_ref,
      :callRef,
      :call_sid,
      :callSid,
      :from,
      :from_number,
      :fromNumber,
      :to,
      :to_number,
      :toNumber,
      :session_key,
      :sessionKey,
      :sip_profile_id,
      :sipProfileId,
      :internal_extension,
      :internalExtension
    )
  end
end
